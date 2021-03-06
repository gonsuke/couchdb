% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_view_compactor).

-include ("couch_db.hrl").

-export([start_compact/2]).

%% @spec start_compact(DbName::binary(), GroupId:binary()) -> ok
%% @doc Compacts the views.  GroupId must not include the _design/ prefix
start_compact(DbName, GroupId) ->
    Pid = couch_view:get_group_server(DbName, <<"_design/",GroupId/binary>>),
    gen_server:cast(Pid, {start_compact, fun compact_group/3}).

%%=============================================================================
%% internal functions
%%=============================================================================

%% @spec compact_group(Group, NewGroup) -> ok
compact_group(Group, EmptyGroup, DbName) ->
    #group{
        current_seq = Seq,
        id_btree = IdBtree,
        name = GroupId,
        views = Views
    } = Group,

    #group{
        id_btree = EmptyIdBtree,
        views = EmptyViews
    } = EmptyGroup,

    {ok, Db} = couch_db:open_int(DbName, []),
    {ok, DbReduce} = couch_btree:full_reduce(Db#db.fulldocinfo_by_id_btree),
    couch_db:close(Db),
    Count = element(1, DbReduce),

    <<"_design", ShortName/binary>> = GroupId,
    TaskName = <<DbName/binary, ShortName/binary>>,
    couch_task_status:add_task(<<"View Group Compaction">>, TaskName, <<"">>),
    BufferSize = list_to_integer(
        couch_config:get("view_compaction", "keyvalue_buffer_size", "2097152")),

    Fun = fun({DocId, _ViewIdKeys} = KV,
            {Bt, Acc, AccSize, TotalCopied, LastId}) ->
        if DocId =:= LastId -> % COUCHDB-999
            ?LOG_ERROR("Duplicates of document `~s` detected in view group `~s`"
                ", database `~s` - view rebuild, from scratch, is required",
                [DocId, GroupId, DbName]),
            exit({view_duplicated_id, DocId});
        true -> ok end,
        AccSize2 = AccSize + ?term_size(KV),
        if AccSize2 >= BufferSize ->
            {ok, Bt2} = couch_btree:add(Bt, lists:reverse([KV|Acc])),
            couch_task_status:update("Copied ~p of ~p Ids (~p%)",
                [TotalCopied, Count, (TotalCopied*100) div Count]),
            {ok, {Bt2, [], 0, TotalCopied + 1 + length(Acc), DocId}};
        true ->
            {ok, {Bt, [KV|Acc], AccSize2, TotalCopied, DocId}}
        end
    end,
    {ok, _, {Bt3, Uncopied, _, _Total, _LastId}} = couch_btree:foldl(
        IdBtree, Fun, {EmptyIdBtree, [], 0, 0, nil}),
    {ok, NewIdBtree} = couch_btree:add(Bt3, lists:reverse(Uncopied)),

    NewViews = lists:map(fun({View, EmptyView}) ->
        compact_view(View, EmptyView, BufferSize)
    end, lists:zip(Views, EmptyViews)),

    NewGroup = EmptyGroup#group{
        id_btree=NewIdBtree,
        views=NewViews,
        current_seq=Seq
    },

    Pid = couch_view:get_group_server(DbName, GroupId),
    gen_server:cast(Pid, {compact_done, NewGroup}).

%% @spec compact_view(View, EmptyView, Retry) -> CompactView
compact_view(View, EmptyView, BufferSize) ->
    {ok, Count} = couch_view:get_row_count(View),

    %% Key is {Key,DocId}
    Fun = fun(KV, {Bt, Acc, AccSize, TotalCopied}) ->
        AccSize2 = AccSize + ?term_size(KV),
        if AccSize2 >= BufferSize ->
            {ok, Bt2} = couch_btree:add(Bt, lists:reverse([KV|Acc])),
            couch_task_status:update("View #~p: copied ~p of ~p KVs (~p%)",
                [View#view.id_num, TotalCopied, Count,
                    (TotalCopied*100) div Count]),
            {ok, {Bt2, [], 0, TotalCopied + 1 + length(Acc)}};
        true ->
            {ok, {Bt, [KV|Acc], AccSize2, TotalCopied}}
        end
    end,

    {ok, _, {Bt3, Uncopied, _, _Total}} = couch_btree:foldl(
        View#view.btree, Fun, {EmptyView#view.btree, [], 0, 0}),
    {ok, NewBt} = couch_btree:add(Bt3, lists:reverse(Uncopied)),
    EmptyView#view{btree = NewBt}.

