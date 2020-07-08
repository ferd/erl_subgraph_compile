erl_subgraph_compile
=====

A rebar plugin to only do partial re-builds of some files without any safety
checks. Relies on a full build having been done recently. Currently does no
valuable error handling.

Prototype intended to turn into an Erlang language server/build server
extension to provide low-cost builds inline with people editing code.

Values speed over correctness.

Use
---

Add the plugin to your rebar config:

    {project_plugins, [
        {erl_subgraph_compile,
         {git, "https://github.com/ferd/erl_subgraph_compile.git", {branch, "master"}}}
    ]}.

Then just call your plugin directly in an existing application:

    $ rebar3 erl_subgraph_compile -f src/rebar_compiler.erl
    ===>      Compiled rebar_compiler.erl
    ===>      Compiled /home/ferd/code/self/rebar3/src/rebar_compiler_yrl.erl
    ===>      Compiled /home/ferd/code/self/rebar3/src/rebar_compiler_mib.erl
    ===>      Compiled /home/ferd/code/self/rebar3/src/rebar_compiler_xrl.erl
    ===>      Compiled /home/ferd/code/self/rebar3/src/rebar_compiler_erl.erl

To call the function on a test file, unless the test directory is specified
by the user in `extra_src_dirs', you will need to call the plugin under the
test profile, which has rebar3 inject the proper configuration values and
re-scopes test dependencies as required:

    $ rebar3 as test erl_subgraph_compile -f test/rebar_compile_SUITE.erl
    ===>      Compiled /home/ferd/code/self/rebar3/test/rebar_compile_SUITE.erl

TODO
----

- Automated Tests
- Working with Erlang-LS folks to get this to a workable state for them
