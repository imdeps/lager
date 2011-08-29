%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with your Erlang distribution. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Corelatus AB.
%% Portions created by Corelatus are Copyright 2003, Corelatus
%% AB. All Rights Reserved.''
%%
%% @doc Module to print out terms for logging. Limits by length rather than depth.
%%
%% The resulting string may be slightly larger than the limit; the intention
%% is to provide predictable CPU and memory consumption for formatting
%% terms, not produce precise string lengths.
%%
%% Typical use:
%%
%%   trunc_io:print(Term, 500).
%%
%% Source license: Erlang Public License.
%% Original author: Matthias Lang, <tt>matthias@corelatus.se</tt>
%%
%% Various changes to this module, most notably the format/3 implementation
%% were added by Andrew Thompson `<andrew@basho.com>'. The module has been renamed
%% to avoid conflicts with the vanilla module.

-module(lager_trunc_io).
-author('matthias@corelatus.se').
%% And thanks to Chris Newcombe for a bug fix 
-export([format/3, print/2, fprint/2, safe/2]).               % interface functions
-version("$Id: trunc_io.erl,v 1.11 2009-02-23 12:01:06 matthias Exp $").

-ifdef(TEST).
-export([perf/0, perf/3, perf1/0, test/0, test/2]). % testing functions
-include_lib("eunit/include/eunit.hrl").
-endif.

format(String, Args, Max) ->
    Parts = re:split(String,
        "(~(?:-??\\d+\\.|\\*\\.|\\.|)(?:-??\\d+\\.|\\*\\.|\\.|)(?:-??\\d+|\\*|)(?:t|)(?:[cfegswpWPBX#bx+ni~]))",
        [{return, list}, trim]),
    Maxlen = Max - length(String),
    format(Parts, Args, Maxlen, [], []).

format([], _Args, Max, Acc, ArgAcc) ->
    FmtArgs = resolve_futures(Max, ArgAcc),
    io_lib:format(lists:flatten(lists:reverse(Acc)), lists:reverse(FmtArgs));
format([[] | T], Args, Max, Acc, ArgAcc) ->
    % discard the null list generated by split
    format(T, Args, Max, Acc, ArgAcc);
format(["~~" | T], Args, Max, Acc, ArgAcc) ->
    format(T, Args, Max+1, ["~~" | Acc], ArgAcc);
format(["~n" | T], Args, Max, Acc, ArgAcc) ->
    % ignore newlines for the purposes of argument indexing
    format(T, Args, Max+1, ["~n" | Acc], ArgAcc);
format(["~i" | T], [AH | AT], Max, Acc, ArgAcc) ->
    % ~i means ignore this argument, but we'll just pass it through
    format(T, AT, Max+2, ["~i" | Acc], [AH | ArgAcc]);
format([[$~|H]| T], [AH1, AH2 | AT], Max, Acc, ArgAcc) when H == "X"; H == "x" ->
    %% ~X consumes 2 arguments. It only prints integers so we can leave it alone
    format(T, AT, Max, ["~X" | Acc], [AH2, AH1 | ArgAcc]);
format([[$~|H]| T], [AH1, _AH2 | AT], Max, Acc, ArgAcc) when H == "W"; H == "P" ->
    %% ~P and ~W consume 2 arguments, the second one being a depth limiter.
    %% trunc_io isn't (yet) depth aware, so we can't honor this format string
    %% safely at the moment, so just treat it like a regular ~p
    %% TODO support for depth limiting
    Input = case H == "P" andalso lager_stdlib:string_p(AH1) of
        true ->
            lists:flatten(AH1);
        _ -> AH1
    end,
    case print(Input, Max + 2) of
        {_Res, Max} ->
            % this isn't the last argument, but it consumed all available space
            % delay calculating the print size until the end
            format(T, AT, Max + 2, ["~s" | Acc], [{future, Input} | ArgAcc]);
        {String, Length} ->
            format(T, AT, Max + 2 - Length, ["~s" | Acc], [String | ArgAcc])
    end;
format([[$~|H]| T], [AH | AT], Max, Acc, ArgAcc) when length(H) == 1 ->
    % single character format specifier, relatively simple
    case H of
        _ when H == "p"; H == "w"; H == "s" ->
            Input = case (H == "s" orelse H == "p") andalso lager_stdlib:string_p(AH) of
                true ->
                    lists:flatten(AH);
                _ -> AH
            end,
            %okay, these are prime candidates for rewriting
            case print(Input, Max + 2) of
                {_Res, Max} ->
                    % this isn't the last argument, but it consumed all available space
                    % delay calculating the print size until the end
                    format(T, AT, Max + 2, ["~s" | Acc], [{future, Input} | ArgAcc]);
                {String, Length} ->
                    {Value, RealLen} = case H of
                        "s" ->
                            % strip off the doublequotes, if applicable
                            Trimmed = case {hd(String), lists:last(String)} == {$", $"} of
                                true ->
                                    string:strip(String, both, $");
                                _ ->
                                    String
                            end,
                            {Trimmed, length(Trimmed)};
                        _ ->
                            {String, Length}
                    end,
                    format(T, AT, Max + 2 - RealLen, ["~s" | Acc], [Value | ArgAcc])
            end;
        _ ->
            % whatever, just pass them on through
            format(T, AT, Max, [[$~ | H] | Acc], [AH | ArgAcc])
    end;
format([[$~|H]| T], [AH | AT], Max, Acc, ArgAcc) ->
    %% its actually simplest to just look at the last character in the string
    case lists:nth(length(H), H) of
        C when C == $p; C == $w; C == $s ->
            %okay, these are prime candidates for rewriting
            Input = case (C == $s orelse C == $p) andalso lager_stdlib:string_p(AH) of
                true ->
                    lists:flatten(AH);
                _ -> AH
            end,
            case print(Input, Max + length(H) + 1) of
                {_Res, Max} ->
                    % this isn't the last argument, but it consumed all available space
                    % delay calculating the print size until the end
                    format(T, AT, Max + length(H) + 1, ["~s" | Acc], [{future, Input} | ArgAcc]);
                {String, Length} ->
                    {Value, RealLen} = case C of
                        $s ->
                            % strip off the doublequotes
                            {string:substr(String, 2, length(String) -2), Length -2};
                        _ ->
                            {String, Length}
                    end,
                    format(T, AT, Max + length(H) + 1 - RealLen, ["~s" | Acc], [Value | ArgAcc])
            end;
        C when C == $P; C == $W ->
            %% ~P and ~W consume 2 arguments, the second one being a depth limiter.
            %% trunc_io isn't (yet) depth aware, so we can't honor this format string
            %% safely at the moment, so just treat it like a regular ~p
            %% TODO support for depth limiting
            [_ | AT2] = AT,
            Input = case C == $P andalso lager_stdlib:string_p(AH) of
                true ->
                    lists:flatten(AH);
                _ -> AH
            end,
            case print(Input, Max + 2) of
                {_Res, Max} ->
                    % this isn't the last argument, but it consumed all available space
                    % delay calculating the print size until the end
                    format(T, AT2, Max + 2, ["~s" | Acc], [{future, Input} | ArgAcc]);
                {String, Length} ->
                    format(T, AT2, Max + 2 - Length, ["~s" | Acc], [String | ArgAcc])
            end;
        C when C == $X; C == $x ->
            %% ~X consumes 2 arguments. It only prints integers so we can leave it alone
            [AH2 | AT2] = AT,
            format(T, AT2, Max, [[$~|H]|Acc], [AH2, AH |ArgAcc]);
        _ ->
            format(T, AT, Max, [[$~|H] | Acc], [AH|ArgAcc])
    end;
format([H | T], Args, Max, Acc, ArgAcc) ->
    format(T, Args, Max, [H | Acc], ArgAcc).

%% for all the really big terms encountered in a format/3 call, try to give each of them an equal share
resolve_futures(Max, Args) ->
    Count = length(lists:filter(fun({future, _}) -> true; (_) -> false end, Args)),
    case Count of
        0 ->
            Args;
        _ ->
            SingleFmt = Max div Count,
            lists:map(fun({future, Value}) -> element(1, print(Value, SingleFmt)); (X) -> X end, Args)
    end.

%% @doc Returns an flattened list containing the ASCII representation of the given
%% term.
-spec fprint(term(), pos_integer()) -> string().
fprint(T, Max) -> 
    {L, _} = print(T, Max),
    lists:flatten(L).

%% @doc Same as print, but never crashes. 
%%
%% This is a tradeoff. Print might conceivably crash if it's asked to
%% print something it doesn't understand, for example some new data
%% type in a future version of Erlang. If print crashes, we fall back
%% to io_lib to format the term, but then the formatting is
%% depth-limited instead of length limited, so you might run out
%% memory printing it. Out of the frying pan and into the fire.
%% 
-spec safe(term(), pos_integer()) -> {string(), pos_integer()} | {string()}.
safe(What, Len) ->
    case catch print(What, Len) of
	{L, Used} when is_list(L) -> {L, Used};
	_ -> {"unable to print" ++ io_lib:write(What, 99)}
    end.	     

%% @doc Returns {List, Length}
-spec print(term(), pos_integer()) -> {iolist(), pos_integer()}.
print(_, Max) when Max < 0 -> {"...", 3};
print(Tuple, Max) when is_tuple(Tuple) -> 
    {TC, Len} = tuple_contents(Tuple, Max-2),
    {[${, TC, $}], Len + 2};

%% @doc We assume atoms, floats, funs, integers, PIDs, ports and refs never need 
%% to be truncated. This isn't strictly true, someone could make an 
%% arbitrarily long bignum. Let's assume that won't happen unless someone
%% is being malicious.
%%
print(Atom, _Max) when is_atom(Atom) ->
    L = atom_to_list(Atom),
    R = case atom_needs_quoting_start(L) of
        true -> lists:flatten([$', L, $']);
        false -> L
    end,
    {R, length(R)};

print(<<>>, _Max) ->
    {"<<>>", 4};

print(Binary, 0) when is_binary(Binary) ->
    {"<<..>>", 6};

print(Binary, Max) when is_binary(Binary) ->
    B = binary_to_list(Binary, 1, lists:min([Max, size(Binary)])),
    {L, Len} = alist_start(B, Max-4),
    {["<<", L, ">>"], Len+4};

print(Float, _Max) when is_float(Float) ->
    %% use the same function io_lib:format uses to print floats
    %% float_to_list is way too verbose.
    L = io_lib_format:fwrite_g(Float),
    {L, length(L)};

print(Fun, Max) when is_function(Fun) ->
    L = erlang:fun_to_list(Fun),
    case length(L) > Max of
        true ->
            S = erlang:max(5, Max),
            Res = string:substr(L, 1, S) ++ "..>",
            {Res, length(Res)};
        _ ->
            {L, length(L)}
    end;

print(Integer, _Max) when is_integer(Integer) ->
    L = integer_to_list(Integer),
    {L, length(L)};

print(Pid, _Max) when is_pid(Pid) ->
    L = pid_to_list(Pid),
    {L, length(L)};

print(Ref, _Max) when is_reference(Ref) ->
    L = erlang:ref_to_list(Ref),
    {L, length(L)};

print(Port, _Max) when is_port(Port) ->
    L = erlang:port_to_list(Port),
    {L, length(L)};

print(List, Max) when is_list(List) ->
    alist_start(List, Max).

%% Returns {List, Length}
tuple_contents(Tuple, Max) ->
    L = tuple_to_list(Tuple),
    list_body(L, Max).

%% Format the inside of a list, i.e. do not add a leading [ or trailing ].
%% Returns {List, Length}
list_body([], _) -> {[], 0};
list_body(_, Max) when Max < 4 -> {"...", 3};
list_body([H|T], Max) -> 
    {List, Len} = print(H, Max),
    {Final, FLen} = list_bodyc(T, Max - Len),
    {[List|Final], FLen + Len};
list_body(X, Max) ->  %% improper list
    {List, Len} = print(X, Max - 1),
    {[$|,List], Len + 1}.

list_bodyc([], _) -> {[], 0};
list_bodyc(_, Max) when Max < 4 -> {"...", 3};
list_bodyc([H|T], Max) -> 
    {List, Len} = print(H, Max),
    {Final, FLen} = list_bodyc(T, Max - Len - 1),
    {[$,, List|Final], FLen + Len + 1};
list_bodyc(X,Max) ->  %% improper list
    {List, Len} = print(X, Max - 1),
    {[$|,List], Len + 1}.

%% The head of a list we hope is ascii. Examples:
%%
%% [65,66,67] -> "ABC"
%% [65,0,67] -> "A"[0,67]
%% [0,65,66] -> [0,65,66]
%% [65,b,66] -> "A"[b,66]
%%
alist_start([], _) -> {"[]", 2};
alist_start(_, Max) when Max < 4 -> {"...", 3};
alist_start([H|T], Max) when H >= 16#20, H =< 16#7e ->  % definitely printable
    {L, Len} = alist([H|T], Max-1),
    {[$"|L], Len + 1};
alist_start([H|T], Max) when H == 9; H == 10; H == 13 ->   % show as space
    {L, Len} = alist(T, Max-1),
    {[$ |L], Len + 1};
alist_start(L, Max) ->
    {R, Len} = list_body(L, Max-2),
    {[$[, R, $]], Len + 2}.

alist([], _) -> {"\"", 1};
alist(_, Max) when Max < 5 -> {"...\"", 4};
alist([H|T], Max) when H >= 16#20, H =< 16#7e ->     % definitely printable
    {L, Len} = alist(T, Max-1),
    {[H|L], Len + 1};
alist([H|T], Max) when H == 9; H == 10; H == 13 ->   % show as space
    {L, Len} = alist(T, Max-1),
    {[$ |L], Len + 1};
alist(L, Max) ->
    {R, Len} = list_body(L, Max-3),
    {[$", $[, R, $]], Len + 3}.

%% is the first character in the atom alphabetic & lowercase?
atom_needs_quoting_start([H|T]) when H >= $a, H =< $z ->
    atom_needs_quoting(T);
atom_needs_quoting_start(_) ->
    true.

atom_needs_quoting([]) ->
    false;
atom_needs_quoting([H|T]) when (H >= $a andalso H =< $z);
                        (H >= $A andalso H =< $Z);
                         H == $@; H == $_ ->
    atom_needs_quoting(T);
atom_needs_quoting(_) ->
    true.

-ifdef(TEST).
%%--------------------
%% The start of a test suite. So far, it only checks for not crashing.
-spec test() -> ok.
test() ->
    test(trunc_io, print).

-spec test(atom(), atom()) -> ok.
test(Mod, Func) ->
    Simple_items = [atom, 1234, 1234.0, {tuple}, [], [list], "string", self(),
		    <<1,2,3>>, make_ref(), fun() -> ok end],
    F = fun(A) ->
		Mod:Func(A, 100),
		Mod:Func(A, 2),
		Mod:Func(A, 20)
	end,

    G = fun(A) ->
		case catch F(A) of
		    {'EXIT', _} -> exit({failed, A});
		    _ -> ok
		end
	end,
    
    lists:foreach(G, Simple_items),
    
    Tuples = [ {1,2,3,a,b,c}, {"abc", def, 1234},
	       {{{{a},b,c,{d},e}},f}],
    
    Lists = [ [1,2,3,4,5,6,7], lists:seq(1,1000),
	      [{a}, {a,b}, {a, [b,c]}, "def"], [a|b], [$a|$b] ],
    
    
    lists:foreach(G, Tuples),
    lists:foreach(G, Lists).

-spec perf() -> ok.
perf() ->
    {New, _} = timer:tc(trunc_io, perf, [trunc_io, print, 1000]),
    {Old, _} = timer:tc(trunc_io, perf, [io_lib, write, 1000]),
    io:fwrite("New code took ~p us, old code ~p\n", [New, Old]).

-spec perf(atom(), atom(), integer()) -> done.
perf(M, F, Reps) when Reps > 0 ->
    test(M,F),
    perf(M,F,Reps-1);
perf(_,_,_) ->
    done.    

%% Performance test. Needs a particularly large term I saved as a binary...
-spec perf1() -> {non_neg_integer(), non_neg_integer()}.
perf1() ->
    {ok, Bin} = file:read_file("bin"),
    A = binary_to_term(Bin),
    {N, _} = timer:tc(trunc_io, print, [A, 1500]),
    {M, _} = timer:tc(io_lib, write, [A]),
    {N, M}.

format_test() ->
    %% simple format strings
    ?assertEqual("foobar", lists:flatten(format("~s", [["foo", $b, $a, $r]], 50))),
    ?assertEqual("\"foobar\"", lists:flatten(format("~p", [["foo", $b, $a, $r]], 50))),
    ?assertEqual("\"foobar\"", lists:flatten(format("~P", [["foo", $b, $a, $r], 10], 50))),
    ?assertEqual("[\"foo\",98,97,114]", lists:flatten(format("~w", [["foo", $b, $a, $r], 10], 50))),
    
    %% complex ones
    ?assertEqual("foobar", lists:flatten(format("~10s", [["foo", $b, $a, $r]], 50))),
    ?assertEqual("\"foobar\"", lists:flatten(format("~10p", [["foo", $b, $a, $r]], 50))),
    ?assertEqual("\"foobar\"", lists:flatten(format("~10P", [["foo", $b, $a, $r], 10], 50))),
    ?assertEqual("[\"foo\",98,97,114]", lists:flatten(format("~10W", [["foo", $b, $a, $r], 10], 50))),
    ok.

atom_quoting_test() ->
    ?assertEqual("hello", lists:flatten(format("~p", [hello], 50))),
    ?assertEqual("'hello world'", lists:flatten(format("~p", ['hello world'], 50))),
    ?assertEqual("hello_world", lists:flatten(format("~p", ['hello_world'], 50))),
    ?assertEqual("'node@127.0.0.1'", lists:flatten(format("~p", ['node@127.0.0.1'], 50))),
    ?assertEqual("node@nohost", lists:flatten(format("~p", [node@nohost], 50))),
    ok.

sane_float_printing_test() ->
    ?assertEqual("1.0", lists:flatten(format("~p", [1.0], 50))),
    ?assertEqual("1.23456789", lists:flatten(format("~p", [1.23456789], 50))),
    ?assertEqual("1.23456789", lists:flatten(format("~p", [1.234567890], 50))),
    ?assertEqual("0.3333333333333333", lists:flatten(format("~p", [1/3], 50))),
    ?assertEqual("0.1234567", lists:flatten(format("~p", [0.1234567], 50))),
    ok.

quote_strip_test() ->
    ?assertEqual("\"hello\"", lists:flatten(format("~p", ["hello"], 50))),
    ?assertEqual("hello", lists:flatten(format("~s", ["hello"], 50))),
    ?assertEqual("hello", lists:flatten(format("~s", [hello], 50))),
    ?assertEqual("hello", lists:flatten(format("~p", [hello], 50))),
    ok.
-endif.
