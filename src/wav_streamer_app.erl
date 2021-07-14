%%%-------------------------------------------------------------------
%% @doc wav_streamer public API
%% @end
%%%-------------------------------------------------------------------

-module(wav_streamer_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    wav_streamer_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
