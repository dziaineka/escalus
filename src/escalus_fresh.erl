-module(escalus_fresh).
-export([story/3,
         story_with_client_list/3,
         story_with_config/3,
         create_users/2,
         freshen_specs/2,
         freshen_spec/2,
         work_on_deleting_users/3, % used by wpool worker
         create_fresh_user/2]).
-export([start/1,
         stop/1,
         clean/0]).

-define(UNREGISTER_WORKERS, 10).
-define(WORKER_OVERRUN_TIME, 3000).
-define(MIN_UNREGISTER_TEMPO, 20000).


-type user_res() :: escalus_users:resource_spec().
-type config() :: escalus:config().

%% @doc
%% Run story with fresh users (non-breaking API).
%% The genererated fresh usernames will consist of the predefined {username, U} value
%% prepended to a unique, per-story suffix.
%% {username, <<"alice">>} -> {username, <<"alice32.632506">>}
-spec story(config(), [user_res()], fun()) -> any().
story(Config, UserSpecs, StoryFun) ->
    escalus:story(create_users(Config, UserSpecs), UserSpecs, StoryFun).

%% @doc
%% See escalus_story:story/3 for the difference between
%% story/3 and story_with_client_list/3.
-spec story_with_client_list(config(), [user_res()], fun()) -> any().
story_with_client_list(Config, UserSpecs, StoryFun) ->
    escalus_story:story_with_client_list(create_users(Config, UserSpecs), UserSpecs, StoryFun).

%% @doc
%% Run story with fresh users AND fresh config passed as first argument
%% If within a story there are references to the top-level Config object,
%% discrepancies may arise when querying this config object for user data,
%% as it will differ from the fresh config actually used by the story.
%% The story arguments can be changed from
%%
%% fresh_story(C,[..],fun(Alice, Bob) ->
%% to
%% fresh_story_with_config(C,[..],fun(FreshConfig, Alice, Bob) ->
%%
%% and any queries rewritten to use FreshConfig within this scope
-spec story_with_config(config(), [user_res()], fun()) -> any().
story_with_config(Config, UserSpecs, StoryFun) ->
    FreshConfig = create_users(Config, UserSpecs),
    escalus_story:story_with_client_list(FreshConfig, UserSpecs,
                                         fun(Args) -> apply(StoryFun, [FreshConfig | Args]) end).

%% @doc
%% Create fresh users for lower-level testing (NOT escalus:stories)
%% The users are created and the config updated with their fresh usernames.
%% The side effect is the creation of XMPP users on a server.
-spec create_users(config(), [user_res()]) -> config().
create_users(Config, UserSpecs) ->
    Suffix = fresh_suffix(),
    FreshSpecs = freshen_specs(Config, UserSpecs, Suffix),
    FreshConfig = escalus_users:create_users(Config, FreshSpecs),
    %% The line below is not needed if we don't want to support cleaning
    ets:insert(nasty_global_table(), {Suffix, FreshConfig}),
    FreshConfig.

%% @doc
%% freshen_spec/2 and freshen_specs/2
%% Creates a fresh spec without creating XMPP users on a server.
%% It is useful when testing some lower level parts of the protocol
%% i.e. some stream features. It is side-effect free.
-spec freshen_specs(config(), [user_res()]) -> [escalus_users:user_spec()].
freshen_specs(Config, UserSpecs) ->
    Suffix = fresh_suffix(),
    lists:map(fun({UserName, Spec}) -> Spec end,
              freshen_specs(Config, UserSpecs, Suffix)).

-spec freshen_spec(config(), escalus_users:user_name() | user_res()) -> escalus_users:user_spec().
freshen_spec(Config, {UserName, Res} = UserSpec) ->
    [FreshSpec] = freshen_specs(Config, [{UserName, 1}]),
    FreshSpec;
freshen_spec(Config, UserName) ->
    freshen_spec(Config, {UserName, 1}).


-spec freshen_specs(config(), [user_res()], binary()) -> [escalus_users:named_user()].
freshen_specs(Config, UserSpecs, Suffix) ->
    FreshSpecs = fresh_specs(Config, UserSpecs, Suffix),
    case length(FreshSpecs) == length(UserSpecs) of
        false ->
            error("failed to get required users");
        true ->
            FreshSpecs
    end.

%% @doc
%% Creates a fresh user along with XMPP user on a server.
-spec create_fresh_user(config(), user_res() | atom()) -> escalus_users:user_spec().
create_fresh_user(Config, {UserName, _Resource} = UserSpec) ->
    Config2 = create_users(Config, [UserSpec]),
    escalus_users:get_userspec(Config2, UserName);
create_fresh_user(Config, UserName) when is_atom(UserName) ->
    create_fresh_user(Config, {UserName, 1}).


%%% Stateful API
%%% Required if we expect to be able to clean up autogenerated users.
start(_Config) ->
    application:ensure_all_started(worker_pool),
    ensure_table_present(nasty_global_table()).
stop(_) ->
    nasty_global_table() ! bye.
-spec clean() -> no_return() | ok.
clean() ->
    wpool:start_sup_pool(unregister_pool, [{workers, ?UNREGISTER_WORKERS},
                                           {overrun_warning, ?WORKER_OVERRUN_TIME}]),
    L = tag(ets:tab2list(nasty_global_table())),
    [wpool:cast(unregister_pool,
                {?MODULE, work_on_deleting_users, [Ord, Item, self()]})
     || {Ord, Item} <- L],
    case collect_deletion_results(L, []) of
        ok ->
            ets:delete_all_objects(nasty_global_table()),
            ok;
        {error, Log} ->
            error(Log)
    end.


-spec collect_deletion_results([{Ord :: non_neg_integer(), Item :: tuple()}],
              [{Ord :: non_neg_integer(), Item :: tuple(), Error :: any()}]) -> {error, any()} | ok.
collect_deletion_results([], []) -> ok;
collect_deletion_results([], Failed) ->
    {error, {unregistering_failed,
             {amount, length(Failed)},
             {unregistered_items, untag(Failed)}}};
collect_deletion_results(Pending, Failed) ->
    receive
        {done, Id} ->
            NewPending = lists:keydelete(Id, 1, Pending),
            collect_deletion_results(NewPending, Failed);
        {error, Id, Error} ->
            {Id, Item} = lists:keyfind(Id, 1, Pending),
            NewPending = lists:keydelete(Id, 1, Pending),
            collect_deletion_results(NewPending, [{Id, Item, Error} | Failed])
    after ?MIN_UNREGISTER_TEMPO ->
              collect_deletion_results([], Failed ++ lists:map(fun({Ord, Item}) -> {Ord, Item, timeout_tempo} end, Pending))
    end.

%%% Internals
nasty_global_table() -> escalus_fresh_db.

work_on_deleting_users(Ord, {_Suffix, Conf} = Item, CollectingPid) ->
    try do_delete_users(Conf) of
        _ ->
            CollectingPid ! {done, Ord}
    catch
        Class:Error ->
            CollectingPid ! {error, Ord, {Class, Error}}
    end,
    ok.

do_delete_users(Conf) ->
    Plist = proplists:get_value(escalus_users, Conf),
    escalus_users:delete_users(Conf, Plist).


ensure_table_present(T) ->
    RunDB = fun() -> ets:new(T, [named_table, public]),
                     receive bye -> ok end end,
    case ets:info(T) of
        undefined ->
            P = spawn(RunDB),
            erlang:register(T, P);
        _nasty_table_is_there_well_run_with_it -> ok
    end.

fresh_specs(Config, TestedUsers, StorySuffix) ->
    AllSpecs = escalus_config:get_config(escalus_users, Config),
    [ make_fresh_username(Spec, StorySuffix)
      || Spec <- select(TestedUsers, AllSpecs) ].

make_fresh_username({N, UserConfig}, Suffix) ->
    {username, OldName} = proplists:lookup(username, UserConfig),
    NewName = << OldName/binary, Suffix/binary >>,
    {N, lists:keyreplace(username, 1, UserConfig, {username, NewName})}.

select(UserResources, FullSpecs) ->
    Fst = fun({A, _}) -> A end,
    UserNames = lists:map(Fst, UserResources),
    lists:filter(fun({Name, _}) -> lists:member(Name, UserNames) end,
                 FullSpecs).

fresh_suffix() ->
    {_, S, US} = erlang:now(),
    L = lists:flatten([integer_to_list(S rem 100), ".", integer_to_list(US)]),
    list_to_binary(L).


tag(L) -> lists:zip(lists:seq(1, length(L)), L).
untag(L) -> [ {Val, Error} || {_Ord, Val, Error} <- lists:sort(L) ].
