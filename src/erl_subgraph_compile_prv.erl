-module(erl_subgraph_compile_prv).
-export([init/1,
         do/1,
         format_error/1]).

-define(ERLC_HOOK, erlc_compile).
-define(PROVIDER, erl_subgraph_compile).
-define(DEPS, [app_discovery]).
-define(DAG_LABEL, "project_apps"). % borrowed from rebar_prv_compile
-define(COMPILER, rebar_compiler_erl).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    State1 = rebar_state:add_provider(
        State,
        providers:create([
            {name, ?PROVIDER},
            {module, ?MODULE},
            {bare, true},
            {deps, ?DEPS},
            {example, "rebar3 erl_subgraph_compile -f src/file.[erl|hrl]"},
            {short_desc, "Recompile .erl files from a project, "
                         "assuming the project was rebuilt recently "
                         "and that the file was already in it."},
            {desc, "Recompile .erl files from a project, "
                   "assuming the project was rebuilt recently "
                   "and that the file was already in it."},
            {opts, [{file, $f, "file", string, "The file to rebuild"}]}])),
    {ok, State1}.
-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.

do(InitState) ->
    %% Build minimal deps' placeholders, assuming that `lock' and
    %% `install_deps' steps have been run before but not in this
    %% invocation yet.
    State = check_deps(InitState),

    %% Make sure the right modules are loaded for some dynamic checks
    _ = code:ensure_loaded(compile),
    _ = code:ensure_loaded(?COMPILER),

    %% Find the submitted file and all the files that depend on it
    %% according to the project DAG
    File = resolve_file(State),
    G = fetch_dag(State),

    Chain = resolve_chain(G, File, State),
    CtxChain = gather_apps(
        [{rebar_app_info:name(App), F, App} || {F, App} <- Chain]
    ),

    %% Rebuild the chain
    [run_pre_hooks(State, AppInfo) || {_, AppInfo, _} <- CtxChain],
    rebar_paths:set_paths([deps, plugins], State),
    [compile_files(G, Files, App, Context) || {Files, App, Context} <- CtxChain],
    rebar_paths:set_paths([plugins], State),
    [run_post_hooks(State, AppInfo) || {_, AppInfo, _} <- CtxChain],

    %% don't store changes
    rebar_compiler_dag:terminate(G),
    {ok, InitState}.

-spec format_error(any()) -> iolist().
format_error({missing_artifact, File}) ->
    io_lib:format("Missing artifact ~ts", [File]);
format_error({bad_project_builder, Name, Type, Module}) ->
    io_lib:format("Error building application ~s:~n     Required project builder ~s function "
                  "~s:build/1 not found", [Name, Type, Module]);
format_error({unknown_project_type, Name, Type}) ->
    io_lib:format("Error building application ~s:~n     "
                  "No project builder is configured for type ~s", [Name, Type]);
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%% ===================================================================
%% Private
%% ===================================================================

%% @private Unsafe code that generates partial specifications of
%% dependencies, assuming they haven't been put in the state yet.
%% This allows skipping over a run of 'install_deps' and lock file
%% verifications.
%%
%% When integrating with a language/build server, we should instead have
%% the server run the install_deps + lock tasks once, and then pass the
%% state to this handler while dropping this function wholesale.
%%
%% The `{erl_subgraph_compile, mock_deps}' key in `State' can be
%% set to `false' to disable this behaviour without code changes.
check_deps(State) ->
    case rebar_state:get(State, {erl_subgraph_compile, mock_deps}, true) of
        true -> check_deps_(State);
        false -> State
    end.

%% @private actual checks when enabled
check_deps_(State1) ->
    DepsDir = rebar_dir:deps_dir(State1),
    {ok, Deps} = file:list_dir(DepsDir),
    ProjAppNames = [rebar_app_info:name(App)
                    || App <- rebar_state:project_apps(State1)],
    AllDepDirs = [BinDir || Dir <- Deps,
                            hd(Dir) =/= ".", % avoid hidden build artifacts
                            BinDir <- [unicode:characters_to_binary(Dir)],
                            not lists:member(BinDir, ProjAppNames)],
    Apps = lists:map(
        fun(Dir) ->
            {ok, App} = rebar_app_info:new(Dir),
            rebar_app_info:out_dir(App, filename:join(DepsDir, Dir))
        end,
        AllDepDirs
    ),
    State2 = rebar_state:update_all_deps(State1, Apps),
    CodePaths = [rebar_app_info:ebin_dir(A) || A <- Apps],
    rebar_state:update_code_paths(State2, all_deps, CodePaths).

%% @private Run the same compilation hooks as the compiler would, but only
%% for erlc itself rather than the whole compile task.
run_pre_hooks(State, AppInfo) ->
    Providers = rebar_state:providers(State),
    AppDir = rebar_app_info:dir(AppInfo),
    rebar_hooks:run_all_hooks(AppDir, pre, ?ERLC_HOOK, Providers, AppInfo, State).

%% @private Run the same compilation hooks as the compiler would, but only
%% for erlc itself rather than the whole compile task.
run_post_hooks(State, AppInfo) ->
    Providers = rebar_state:providers(State),
    AppDir = rebar_app_info:dir(AppInfo),
    rebar_hooks:run_all_hooks(AppDir, post, ?ERLC_HOOK, Providers, AppInfo, State).

%% @private get the file submitted by the user and return it in
%% a way that will match the compiler DAG later on (absolute
%% paths)
resolve_file(State) ->
    {Args, _} = rebar_state:command_parsed_args(State),
    File = proplists:get_value(file, Args),
    case File of
        undefined ->
            rebar_api:error("-f <file> argument required", []),
            rebar_api:abort();
        _ ->
            ok
    end,
    rebar_file_utils:absolute_path(File).

%% @private load the DAG for the compiler artifacts; we won't redo
%% the analysis and will just assume that everything is correct
%% in there.
%% We hide it in this private function because using this code with
%% the Erlang code server will likely be done live and avoiding
%% reloading could be an end objective that's worthwhile.
%% We could also potentially hijack the DAG and load it in an
%% unsafe way so it goes faster. This function is just
%% the way to separate that potential future code from the current
%% stuff.
fetch_dag(State) ->
    CritMeta = [], % gonna have to keep this in sync with rebar_prv_compile
    rebar_compiler_dag:init(
        rebar_dir:deps_dir(State),
        ?COMPILER,
        ?DAG_LABEL,
        CritMeta
    ).


%% @private Find all the files that depend on `File' in the DAG
%% from a previous build. Each file is to be paired with the related
%% `AppInfo' record to which it belongs. This latter information
%% isn't contained in the DAG so we rebuild it internally.
-spec resolve_chain(DAG, File, rebar_state:t()) ->
    [{File, rebar_app_info:t()}, ...] when
      DAG :: rebar_compiler_dag:dag(),
      File :: file:filename_all().
resolve_chain(G, File, State) ->
    %% the compiler DAG uses A -> B to indicate A is a dependency
    %% of B.
    %% In the case of build artifact, it uses the `artifact' label
    %% on the edge, and the `{artifact, Meta}' label on the vertex.
    %%
    %% The chain should be resolved in level-order to ensure
    %% properly ordered compilation, and we then annotate the chain
    %% with the proper OTP apps.
    map_apps(level_order(G, File), State).

%% @private level-order DAG traversal.
%% diagraph and diagraph_util neither have the actual level-order
%% traversal utils (only pre- and post-order) so we need to write
%% one ourselves.
level_order(G, File) -> level_order(G, File, []).

level_order(G, File, Todo) ->
    %% Assume the file is found, hard crash if not.
    case digraph:vertex(G, File) of
        {_, {artifact, _}} -> % artifact file, ignore
            case Todo of
                [Next|NewTodo] ->
                    level_order(G, Next, NewTodo);
                [] ->
                    []
            end;
        {_, _} -> % exists, label is time-based
            Out = digraph:in_neighbours(G, File),
            case Todo ++ Out of
                [Next|NewTodo] ->
                    [File | level_order(G, Next, NewTodo)];
                [] ->
                    []
            end
    end.

%% @private for a given file, find the OTP app that owns it. We need
%% this to be able to extract the proper compile-time options, and
%% the code is unfortunately not super effective.
%% Copy/pasted and adapted from rebar_compiler_dag private functions.
map_apps(Chain, State) ->
    AppPaths = lists:sort([{filename:split(
                   rebar_utils:to_list(rebar_app_info:dir(AppInfo))
                 ), AppInfo}
                || AppInfo <- rebar_state:project_apps(State)]),
    map_apps_(Chain, AppPaths).

map_apps_([H|T], AppPaths) ->
    {App, _Path} = Cache = find_app(H, AppPaths),
    [{H, App} | map_apps_(T, AppPaths, Cache)].

map_apps_([], _, _) ->
    [];
map_apps_([H|T], AppPaths, Cache) ->
    {App, _Path} = NewCache = find_cached_app(H, Cache, AppPaths),
    [{H, App} | map_apps_(T, AppPaths, NewCache)].

%% @private Re-group all files that belong to the same OTP application
%% together as a single entry. By doing this based on the DAG order
%% we also implicitly define the required compilation order.
%%
%% Do note that we need to manually figure out which files in an app
%% belong to its `extra_src_dirs' since thouse can have unrelated
%% `out_dirs', and therefore a partial rebuild wouldn't work well with
%% say CT suites if the files went with the regular beams.
gather_apps([]) ->
    [];
gather_apps([{AppName, File, AppInfo}|Rest]) ->
    {Files, Without} = gather_apps(AppName, Rest, [], []),
    ExtraApps = annotate_extras(AppInfo),
    Mapped = map_extras([AppInfo|ExtraApps], [File|Files]),
    Mapped ++ gather_apps(Without).

%% @private find all terms in a list that contain the an app named `Name'
gather_apps(_Name, [], With, Without) ->
    {lists:reverse(With), lists:reverse(Without)};
gather_apps(Name, [{Name, File, _AppInfo}|Rest], With, Without) ->
    gather_apps(Name, Rest, [File|With], Without);
gather_apps(Name, [H|T], With, Without) ->
    gather_apps(Name, T, With, [H|Without]).

%% @private From a list of AppInfo records (which include the fake
%% ExtraApps ones), find which one of them has the given files in
%% each of these's `src_dir' entries. Extract all files in `File'
%% to map them to one of the `Apps' specified.
%%
%% Assume that all files belong to known apps, otherwise hard crash.
map_extras(_, []) ->
    [];
map_extras([AppInfo|Apps], Files) ->
    %% We absolutely rely on lists:partition/2 being stable in the
    %% order returned
    {In, Out} = lists:partition(fun(F) -> in_app_source(F, AppInfo) end, Files),
    case In of
        [] ->
            map_extras(Apps, Files);
        _ ->
            Ctx = maps:merge(default_ctx(), ?COMPILER:context(AppInfo)),
            [{In, AppInfo, Ctx} | map_extras(Apps, Out)]
    end.

%% @private predicate checking the ownership of a file to some `src_dir'
in_app_source(File, AppInfo) ->
    Opts = rebar_app_info:opts(AppInfo),
    SrcDirs = rebar_dir:src_dirs(Opts, ["src"]),
    AppDir = rebar_app_info:dir(AppInfo),
    AbsDirs = [filename:join(AppDir, SrcDir) || SrcDir <- SrcDirs],
    lists:any(fun(Dir) -> lists:prefix(Dir, File) end, AbsDirs).

%% @private invoke the compiler on the file chain needing to be rebuilt
compile_files(G, AllFoundFiles, AppInfo, Context) ->
    #{out_mappings := Mappings,
      src_ext := SrcExt} = Context,

    BaseOpts = rebar_app_info:opts(AppInfo),

    %% Drop headers and unrelated stuff we can't rebuild
    FoundFiles = lists:filter(fun(F) -> filename:extension(F) == SrcExt end,
                              AllFoundFiles),
    %% Mark all the files as needed by refreshing their values; play with the
    %% DAG Internals, which we hope not to save to leave it clean!
    {{Y,Mo,D},Hour} = max(calendar:local_time(), calendar:universal_time()),
    LastModified = {{Y+1, Mo, D}, Hour}, % all files undeniably in the future.
    [digraph:add_vertex(G, F, LastModified) || F <- FoundFiles],

    %% This bit does more analysis than we need, but it also sets up a bunch of
    %% options that can vary for specific files, so we keep using it.
    {{FirstFiles, FirstFileOpts},
     {RestFiles, Opts}} = ?COMPILER:needed_files(G, FoundFiles, Mappings, AppInfo),

    %% don't track results, just do the actual compiling as
    %% `rebar_compiler' module would.
    compile_each(FirstFiles, FirstFileOpts, BaseOpts, Mappings, ?COMPILER),
    case RestFiles of
        {Sequential, Parallel} -> % parallelizable form
            compile_each(Sequential, Opts, BaseOpts, Mappings, ?COMPILER),
            compile_parallel(Parallel, Opts, BaseOpts, Mappings, ?COMPILER);
        _ when is_list(RestFiles) -> % traditional sequential build
            compile_each(RestFiles, Opts, BaseOpts, Mappings, ?COMPILER)
    end,
    ok.

%% ===================================================================
%% Copied from rebar_compiler_dag
%% ===================================================================

%% Look for the app to which the path belongs; needed to
%% go from an edge between files in the DAG to building
%% app-related orderings
find_app(Path, AppPaths) ->
    find_app_(filename:split(Path), AppPaths).

%% A cached search for the app to which a path belongs;
%% the assumption is that sorted edges and common relationships
%% are going to be between local files within an app most
%% of the time; so we first look for the same path as a
%% prior match to avoid searching _all_ potential candidates.
%% If it doesn't work, go for the normal search.
find_cached_app(Path, {Name, AppPath}, AppPaths) ->
    Split = filename:split(Path),
    case find_app_(Split, [{AppPath, Name}]) of
        not_found -> find_app_(Split, AppPaths);
        LastEntry -> LastEntry
    end.

%% Do the actual recursive search
find_app_(_Path, []) ->
    not_found;
find_app_(Path, [{AppPath, AppName}|Rest]) ->
    case lists:prefix(AppPath, Path) of
        true ->
            {AppName, AppPath};
        false when AppPath > Path ->
            not_found;
        false ->
            find_app_(Path, Rest)
    end.

%% ===================================================================
%% Copied from rebar_compiler
%% ===================================================================
annotate_extras(AppInfo) ->
    ExtraDirs = rebar_dir:extra_src_dirs(rebar_app_info:opts(AppInfo), []),
    OldSrcDirs = rebar_app_info:get(AppInfo, src_dirs, ["src"]),
    AppDir = rebar_app_info:dir(AppInfo),
    lists:map(fun(Dir) ->
        EbinDir = filename:join(rebar_app_info:out_dir(AppInfo), Dir),
        %% need a unique name to prevent lookup issues that clobber entries
        AppName = unicode:characters_to_binary(
            [rebar_app_info:name(AppInfo), "_", Dir]
        ),
        AppInfo0 = rebar_app_info:name(AppInfo, AppName),
        AppInfo1 = rebar_app_info:ebin_dir(AppInfo0, EbinDir),
        AppInfo2 = rebar_app_info:set(AppInfo1, src_dirs, [Dir]),
        AppInfo3 = rebar_app_info:set(AppInfo2, extra_src_dirs, OldSrcDirs),
        add_to_includes( % give access to .hrl in app's src/
            AppInfo3,
            [filename:join([AppDir, D]) || D <- OldSrcDirs]
        )
    end,
    [ExtraDir || ExtraDir <- ExtraDirs,
                 filelib:is_dir(filename:join(AppDir, ExtraDir))]
    ).

add_to_includes(AppInfo, Dirs) ->
    Opts = rebar_app_info:opts(AppInfo),
    List = rebar_opts:get(Opts, erl_opts, []),
    NewErlOpts = [{i, Dir} || Dir <- Dirs] ++ List,
    NewOpts = rebar_opts:set(Opts, erl_opts, NewErlOpts),
    rebar_app_info:opts(AppInfo, NewOpts).

compile_each([], _Opts, _Config, _Outs, _CompilerMod) ->
    [];
compile_each([Source | Rest], Opts, Config, Outs, CompilerMod) ->
    case erlang:function_exported(CompilerMod, compile_and_track, 4) of
        false ->
            do_compile(CompilerMod, Source, Outs, Config, Opts),
            compile_each(Rest, Opts, Config, Outs, CompilerMod);
        true ->
            do_compile_and_track(CompilerMod, Source, Outs, Config, Opts)
            ++ compile_each(Rest, Opts, Config, Outs, CompilerMod)
    end.

%% just replaced ?DEBUG with rebar_api:info
do_compile(CompilerMod, Source, Outs, Config, Opts) ->
    case CompilerMod:compile(Source, Outs, Config, Opts) of
        ok ->
            rebar_api:info("~tsCompiled ~ts", [rebar_utils:indent(1), filename:basename(Source)]);
        {ok, Warnings} ->
            report(Warnings),
            rebar_api:info("~tsCompiled ~ts", [rebar_utils:indent(1), filename:basename(Source)]);
        skipped ->
            rebar_api:info("~tsSkipped ~ts", [rebar_utils:indent(1), filename:basename(Source)]);
        Error ->
            NewSource = format_error_source(Source, Config),
            rebar_api:error("Compiling ~ts failed", [NewSource]),
            maybe_report(Error),
            rebar_api:info("Compilation failed: ~p", [Error]),
            rebar_api:abort()
    end.

%% just replaced ?DEBUG with rebar_api:info
do_compile_and_track(CompilerMod, Source, Outs, Config, Opts) ->
    case CompilerMod:compile_and_track(Source, Outs, Config, Opts) of
        {ok, Tracked} ->
            rebar_api:info("~tsCompiled ~ts", [rebar_utils:indent(1), filename:basename(Source)]),
            Tracked;
        {ok, Tracked, Warnings} ->
            report(Warnings),
            rebar_api:info("~tsCompiled ~ts", [rebar_utils:indent(1), filename:basename(Source)]),
            Tracked;
        skipped ->
            rebar_api:info("~tsSkipped ~ts", [rebar_utils:indent(1), filename:basename(Source)]),
            [];
        Error ->
            NewSource = format_error_source(Source, Config),
            rebar_api:error("Compiling ~ts failed", [NewSource]),
            maybe_report(Error),
            rebar_api:info("Compilation failed: ~p", [Error]),
            rebar_api:abort()
    end.

compile_parallel(Targets, Opts, BaseOpts, Mappings, CompilerMod) ->
    Tracking = erlang:function_exported(CompilerMod, compile_and_track, 4),
    rebar_parallel:queue(
        Targets,
        fun compile_worker/2, [Opts, BaseOpts, Mappings, CompilerMod],
        fun compile_handler/2, [BaseOpts, Tracking]
    ).

compile_worker(Source, [Opts, Config, Outs, CompilerMod]) ->
    Result = case erlang:function_exported(CompilerMod, compile_and_track, 4) of
        false ->
            CompilerMod:compile(Source, Outs, Config, Opts);
        true ->
            CompilerMod:compile_and_track(Source, Outs, Config, Opts)
    end,
    %% Bundle the source to allow proper reporting in the handler:
    {Result, Source}.

%% just replaced ?DEBUG with rebar_api:info
compile_handler({ok, Source}, _Args) ->
    rebar_api:info("~sCompiled ~s", [rebar_utils:indent(1), Source]),
    ok;
compile_handler({{ok, Tracked}, Source}, [_, Tracking]) when Tracking ->
    rebar_api:info("~sCompiled ~s", [rebar_utils:indent(1), Source]),
    {ok, Tracked};
compile_handler({{ok, Warnings}, Source}, _Args) ->
    report(Warnings),
    rebar_api:info("~sCompiled ~s", [rebar_utils:indent(1), Source]),
    ok;
compile_handler({{ok, Tracked, Warnings}, Source}, [_, Tracking]) when Tracking ->
    report(Warnings),
    rebar_api:info("~sCompiled ~s", [rebar_utils:indent(1), Source]),
    {ok, Tracked};
compile_handler({skipped, Source}, _Args) ->
    rebar_api:info("~sSkipped ~s", [rebar_utils:indent(1), Source]),
    ok;
compile_handler({Error, Source}, [Config | _Rest]) ->
    NewSource = format_error_source(Source, Config),
    rebar_api:error("Compiling ~ts failed", [NewSource]),
    maybe_report(Error),
    rebar_api:abort().

maybe_report(Reportable) ->
    rebar_base_compiler:maybe_report(Reportable).

format_error_source(Path, Opts) ->
    rebar_base_compiler:format_error_source(Path, Opts).

report(Messages) ->
    rebar_base_compiler:report(Messages).

default_ctx() ->
    #{dependencies_opts => []}.

