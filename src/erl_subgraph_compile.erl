-module(erl_subgraph_compile).

-export([init/1]).

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    {ok, State1} = erl_subgraph_compile_prv:init(State),
    {ok, State1}.
