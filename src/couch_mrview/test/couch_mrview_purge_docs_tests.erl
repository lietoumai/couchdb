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

-module(couch_mrview_purge_docs_tests).

-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_mrview/include/couch_mrview.hrl").

-define(TIMEOUT, 1000).


setup() ->
    {ok, Db} = couch_mrview_test_util:init_db(?tempdb(), map, 5),
    Db.

teardown(Db) ->
    couch_db:close(Db),
    couch_server:delete(couch_db:name(Db), [?ADMIN_CTX]),
    ok.

view_purge_test_() ->
    {
        "Map views",
        {
            setup,
            fun test_util:start_couch/0, fun test_util:stop_couch/1,
            {
                foreach,
                fun setup/0, fun teardown/1,
                [
                    fun test_purge_single/1,
                    fun test_purge_partial/1,
                    fun test_purge_complete/1,
                    fun test_purge_nochange/1,
                    fun test_purge_with_rewind_purgeseq/1,
                    fun test_purge_compact_size_check/1,
                    fun test_purge_compact_for_stale_purge_cp_without_client/1,
                    fun test_purge_compact_for_stale_purge_cp_with_client/1
                ]
            }
        }
    }.


test_purge_single(Db) ->
    ?_test(begin
        Result = run_query(Db, []),
        Expect = {ok, [
            {meta, [{total, 5}, {offset, 0}]},
            {row, [{id, <<"1">>}, {key, 1}, {value, 1}]},
            {row, [{id, <<"2">>}, {key, 2}, {value, 2}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect, Result),

        FDI = couch_db:get_full_doc_info(Db, <<"1">>),
        Rev = get_rev(FDI),
        {ok, [{ok, _PRevs}]} = couch_db:purge_docs(
            Db,
            [{<<"UUID1">>, <<"1">>, [Rev]}]
        ),
        {ok, Db2} = couch_db:reopen(Db),

        Result2 = run_query(Db2, []),
        Expect2 = {ok, [
            {meta, [{total, 4}, {offset, 0}]},
            {row, [{id, <<"2">>}, {key, 2}, {value, 2}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect2, Result2),

        ok
    end).


test_purge_partial(Db) ->
    ?_test(begin
        Result = run_query(Db, []),
        Expect = {ok, [
            {meta, [{total, 5}, {offset, 0}]},
            {row, [{id, <<"1">>}, {key, 1}, {value, 1}]},
            {row, [{id, <<"2">>}, {key, 2}, {value, 2}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect, Result),

        FDI1 = couch_db:get_full_doc_info(Db, <<"1">>), Rev1 = get_rev(FDI1),
        Update = {[
            {'_id', <<"1">>},
            {'_rev', couch_doc:rev_to_str({1, [crypto:hash(md5, <<"1.2">>)]})},
            {'val', 1.2}
        ]},
        {ok, [_Rev2]} = save_docs(Db, [Update], [replicated_changes]),

        PurgeInfos = [{<<"UUID1">>, <<"1">>, [Rev1]}],

        {ok, _} = couch_db:purge_docs(Db, PurgeInfos),
        {ok, Db2} = couch_db:reopen(Db),

        Result2 = run_query(Db2, []),
        Expect2 = {ok, [
            {meta, [{total, 5}, {offset, 0}]},
            {row, [{id, <<"1">>}, {key, 1.2}, {value, 1.2}]},
            {row, [{id, <<"2">>}, {key, 2}, {value, 2}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect2, Result2),

        ok
    end).

test_purge_complete(Db) ->
    ?_test(begin
        Result = run_query(Db, []),
        Expect = {ok, [
            {meta, [{total, 5}, {offset, 0}]},
            {row, [{id, <<"1">>}, {key, 1}, {value, 1}]},
            {row, [{id, <<"2">>}, {key, 2}, {value, 2}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect, Result),

        FDI1 = couch_db:get_full_doc_info(Db, <<"1">>), Rev1 = get_rev(FDI1),
        FDI2 = couch_db:get_full_doc_info(Db, <<"2">>), Rev2 = get_rev(FDI2),
        FDI5 = couch_db:get_full_doc_info(Db, <<"5">>), Rev5 = get_rev(FDI5),

        PurgeInfos = [
            {<<"UUID1">>, <<"1">>, [Rev1]},
            {<<"UUID2">>, <<"2">>, [Rev2]},
            {<<"UUID5">>, <<"5">>, [Rev5]}
        ],
        {ok, _} = couch_db:purge_docs(Db, PurgeInfos),
        {ok, Db2} = couch_db:reopen(Db),

        Result2 = run_query(Db2, []),
        Expect2 = {ok, [
            {meta, [{total, 2}, {offset, 0}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]}
        ]},
        ?assertEqual(Expect2, Result2),

        ok
    end).


test_purge_nochange(Db) ->
    ?_test(begin
        Result = run_query(Db, []),
        Expect = {ok, [
            {meta, [{total, 5}, {offset, 0}]},
            {row, [{id, <<"1">>}, {key, 1}, {value, 1}]},
            {row, [{id, <<"2">>}, {key, 2}, {value, 2}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect, Result),

        FDI1 = couch_db:get_full_doc_info(Db, <<"1">>),
        Rev1 = get_rev(FDI1),

        PurgeInfos = [
            {<<"UUID1">>, <<"6">>, [Rev1]}
        ],
        {ok, _} = couch_db:purge_docs(Db, PurgeInfos),
        {ok, Db2} = couch_db:reopen(Db),

        Result2 = run_query(Db2, []),
        Expect2 = {ok, [
            {meta, [{total, 5}, {offset, 0}]},
            {row, [{id, <<"1">>}, {key, 1}, {value, 1}]},
            {row, [{id, <<"2">>}, {key, 2}, {value, 2}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect2, Result2),

        ok
    end).


test_purge_with_rewind_purgeseq(Db) ->
    ?_test(begin
        Result = run_query(Db, []),
        Expect = {ok, [
            {meta, [{total, 5}, {offset, 0}]},
            {row, [{id, <<"1">>}, {key, 1}, {value, 1}]},
            {row, [{id, <<"2">>}, {key, 2}, {value, 2}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect, Result),
        FDI = couch_db:get_full_doc_info(Db, <<"1">>),
        Rev = get_rev(FDI),
        {ok, [{ok, _PRevs}]} = couch_db:purge_docs(
            Db,
            [{<<"UUID1">>, <<"1">>, [Rev]}]
        ),
        {ok, Db2} = couch_db:reopen(Db),
        Result2 = run_query(Db2, []),
        Expect2 = {ok, [
            {meta, [{total, 4}, {offset, 0}]},
            {row, [{id, <<"2">>}, {key, 2}, {value, 2}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect2, Result2),

        FoldFun = fun(#doc{id = DocId, body = {_Props}}, DocIdsAcc) ->
            {ok, [DocId | DocIdsAcc]}
        end,
        Opts = [
            {start_key, list_to_binary(?LOCAL_DOC_PREFIX ++ "purge-")}
        ],
        {ok, LocalPDocIds} = couch_db:fold_local_docs(Db2, FoldFun, [], Opts),
        [LocalPurgeDocId | _Rest] = LocalPDocIds,

        {ok, Db3} = couch_db:reopen(Db2),
        {ok, LocalPurgeDoc} = couch_db:open_doc(Db2, LocalPurgeDocId, []),
        {Props} = couch_doc:to_json_obj(LocalPurgeDoc, []),
        RewindPurgeDoc = couch_doc:from_json_obj({[
            {<<"_id">>, LocalPurgeDocId},
            {<<"_rev">>, couch_util:get_value(<<"_rev">>, Props)},
            {<<"type">>, couch_util:get_value(<<"type">>, Props)},
            {<<"updated_on">>, couch_util:get_value(<<"updated_on">>, Props)},
            {<<"verify_module">>,
                couch_util:get_value(<<"verify_module">>, Props)},
            {<<"verify_function">>,
                couch_util:get_value(<<"verify_function">>, Props)},
            {<<"verify_options">>,
                couch_util:get_value(<<"verify_options">>, Props)},
            {<<"purge_seq">>, 0}
        ]}),
        {ok, _} = couch_db:update_doc(Db3, RewindPurgeDoc, []),

        {ok, Db4} = couch_db:reopen(Db3),
        FDI2 = couch_db:get_full_doc_info(Db, <<"2">>),
        Rev2 = get_rev(FDI2),
        {ok, [{ok, _PRevs2}]} = couch_db:purge_docs(
            Db,
            [{<<"UUID1">>, <<"2">>, [Rev2]}]
        ),

        {ok, Db5} = couch_db:reopen(Db4),
        Result4 = run_query(Db5, []),
        Expect4 = {ok, [
            {meta, [{total, 3}, {offset, 0}]},
            {row, [{id, <<"3">>}, {key, 3}, {value, 3}]},
            {row, [{id, <<"4">>}, {key, 4}, {value, 4}]},
            {row, [{id, <<"5">>}, {key, 5}, {value, 5}]}
        ]},
        ?assertEqual(Expect4, Result4),

        ok
    end).


test_purge_compact_size_check(Db) ->
    ?_test(begin
        DbName = couch_db:name(Db),
        Docs = couch_mrview_test_util:make_docs(normal, 6, 200),
        {ok, Db1} = couch_mrview_test_util:save_docs(Db, Docs),
        _Result = run_query(Db1, []),
        DiskSizeBefore = db_disk_size(DbName),

        PurgedDocsNum = 150,
        IdsRevs = lists:foldl(fun(Id, CIdRevs) ->
            Id1 = docid(Id),
            FDI1 = couch_db:get_full_doc_info(Db1, Id1),
            Rev1 = get_rev(FDI1),
            UUID1 = uuid(Id),
            [{UUID1, Id1, [Rev1]} | CIdRevs]
        end, [], lists:seq(1, PurgedDocsNum)),
        {ok, _} = couch_db:purge_docs(Db1, IdsRevs),

        {ok, Db2} = couch_db:reopen(Db1),
        _Result1 = run_query(Db2, []),
        {ok, PurgedIdRevs} = couch_db:fold_purge_infos(
            Db2,
            0,
            fun fold_fun/2,
            [],
            []
        ),
        ?assertEqual(PurgedDocsNum, length(PurgedIdRevs)),
        config:set("couchdb", "file_compression", "snappy", false),

        {ok, Db3} = couch_db:open_int(DbName, []),
        {ok, _CompactPid} = couch_db:start_compact(Db3),
        wait_compaction(DbName, "database", ?LINE),
        ok = couch_db:close(Db3),
        DiskSizeAfter = db_disk_size(DbName),
        ?assert(DiskSizeBefore > DiskSizeAfter),

        ok
    end).


test_purge_compact_for_stale_purge_cp_without_client(Db) ->
    ?_test(begin
        DbName = couch_db:name(Db),
        % add more documents to database for purge
        Docs = couch_mrview_test_util:make_docs(normal, 6, 200),
        {ok, Db1} = couch_mrview_test_util:save_docs(Db, Docs),

        % change PurgedDocsLimit to 10 from 1000 to
        % avoid timeout of eunit test
        PurgedDocsLimit = 10,
        couch_db:set_purge_infos_limit(Db1, PurgedDocsLimit),

        % purge 150 documents
        PurgedDocsNum = 150,
        PurgeInfos = lists:foldl(fun(Id, CIdRevs) ->
            Id1 = docid(Id),
            FDI1 = couch_db:get_full_doc_info(Db1, Id1),
            Rev1 = get_rev(FDI1),
            UUID1 = uuid(Id),
            [{UUID1, Id1, [Rev1]} | CIdRevs]
        end, [], lists:seq(1, PurgedDocsNum)),
        {ok, _} = couch_db:purge_docs(Db1, PurgeInfos),

        {ok, Db2} = couch_db:reopen(Db1),
        {ok, PurgedIdRevs} = couch_db:fold_purge_infos(
            Db2,
            0,
            fun fold_fun/2,
            [],
            []
        ),
        ?assertEqual(PurgedDocsNum, length(PurgedIdRevs)),

        % run compaction to trigger pruning of purge tree
        {ok, Db3} = couch_db:open_int(DbName, []),
        {ok, _CompactPid} = couch_db:start_compact(Db3),
        wait_compaction(DbName, "database", ?LINE),
        ok = couch_db:close(Db3),

        % check the remaining purge requests in purge tree
        {ok, Db4} = couch_db:reopen(Db3),
        {ok, OldestPSeq} = couch_db:get_oldest_purge_seq(Db4),
        {ok, PurgedIdRevs2} = couch_db:fold_purge_infos(
            Db4,
            OldestPSeq - 1,
            fun fold_fun/2,
            [],
            []
        ),
        ?assertEqual(PurgedDocsLimit, length(PurgedIdRevs2)),

        ok
    end).


test_purge_compact_for_stale_purge_cp_with_client(Db) ->
    ?_test(begin
        DbName = couch_db:name(Db),
        % add more documents to database for purge
        Docs = couch_mrview_test_util:make_docs(normal, 6, 200),
        {ok, Db1} = couch_mrview_test_util:save_docs(Db, Docs),

        % change PurgedDocsLimit to 10 from 1000 to
        % avoid timeout of eunit test
        PurgedDocsLimit = 10,
        couch_db:set_purge_infos_limit(Db1, PurgedDocsLimit),
        _Result = run_query(Db1, []),

        % purge 150 documents
        PurgedDocsNum = 150,
        IdsRevs = lists:foldl(fun(Id, CIdRevs) ->
            Id1 = docid(Id),
            FDI1 = couch_db:get_full_doc_info(Db1, Id1),
            Rev1 = get_rev(FDI1),
            UUID1 = uuid(Id),
            [{UUID1, Id1, [Rev1]} | CIdRevs]
        end, [], lists:seq(1, PurgedDocsNum)),
        {ok, _} = couch_db:purge_docs(Db1, IdsRevs),

        % run query again to reflect purge requests
        % to mrview
        {ok, Db2} = couch_db:reopen(Db1),
        _Result1 = run_query(Db2, []),
        {ok, PurgedIdRevs} = couch_db:fold_purge_infos(
            Db2,
            0,
            fun fold_fun/2,
            [],
            []
        ),
        ?assertEqual(PurgedDocsNum, length(PurgedIdRevs)),

        % run compaction to trigger pruning of purge tree
        {ok, Db3} = couch_db:open_int(DbName, []),
        {ok, _CompactPid} = couch_db:start_compact(Db3),
        wait_compaction(DbName, "database", ?LINE),
        ok = couch_db:close(Db3),

        % check the remaining purge requests in purge tree
        {ok, Db4} = couch_db:reopen(Db3),
        {ok, OldestPSeq} = couch_db:get_oldest_purge_seq(Db4),
        {ok, PurgedIdRevs2} = couch_db:fold_purge_infos(
            Db4,
            OldestPSeq - 1,
            fun fold_fun/2,
            [],
            []
        ),
        ?assertEqual(PurgedDocsLimit, length(PurgedIdRevs2)),

        ok
    end).


run_query(Db, Opts) ->
    couch_mrview:query_view(Db, <<"_design/bar">>, <<"baz">>, Opts).


save_docs(Db, JsonDocs, Options) ->
    Docs = lists:map(fun(JDoc) ->
        couch_doc:from_json_obj(?JSON_DECODE(?JSON_ENCODE(JDoc)))
                     end, JsonDocs),
    Opts = [full_commit | Options],
    case lists:member(replicated_changes, Options) of
        true ->
            {ok, []} = couch_db:update_docs(
                Db, Docs, Opts, replicated_changes),
            {ok, lists:map(fun(Doc) ->
                {Pos, [RevId | _]} = Doc#doc.revs,
                {Pos, RevId}
                           end, Docs)};
        false ->
            {ok, Resp} = couch_db:update_docs(Db, Docs, Opts),
            {ok, [Rev || {ok, Rev} <- Resp]}
    end.


get_rev(#full_doc_info{} = FDI) ->
    #doc_info{
        revs = [#rev_info{} = PrevRev | _]
    } = couch_doc:to_doc_info(FDI),
    PrevRev#rev_info.rev.

db_disk_size(DbName) ->
    {ok, Db} = couch_db:open_int(DbName, []),
    {ok, Info} = couch_db:get_db_info(Db),
    ok = couch_db:close(Db),
    active_size(Info).

active_size(Info) ->
    couch_util:get_nested_json_value({Info}, [sizes, active]).

wait_compaction(DbName, Kind, Line) ->
    WaitFun = fun() ->
        case is_compaction_running(DbName) of
            true -> wait;
            false -> ok
        end
    end,
    case test_util:wait(WaitFun, 10000) of
        timeout ->
            erlang:error({assertion_failed,
                [{module, ?MODULE},
                    {line, Line},
                    {reason, "Timeout waiting for "
                        ++ Kind
                        ++ " database compaction"}]});
        _ ->
            ok
    end.

is_compaction_running(DbName) ->
    {ok, Db} = couch_db:open_int(DbName, []),
    {ok, DbInfo} = couch_db:get_db_info(Db),
    couch_db:close(Db),
    couch_util:get_value(compact_running, DbInfo).

fold_fun({_PSeq, _UUID, Id, Revs}, Acc) ->
    {ok, [{Id, Revs} | Acc]}.

docid(I) ->
    list_to_binary(integer_to_list(I)).

uuid(I) ->
    Str = io_lib:format("UUID~4..0b", [I]),
    iolist_to_binary(Str).
