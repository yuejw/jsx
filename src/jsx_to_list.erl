%% The MIT License

%% Copyright (c) 2010-2013 Alisdair Sullivan <alisdairsullivan@yahoo.ca>

%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:

%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.

%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.


-module(jsx_to_list).

-export([to_term/2]).
-export([init/1, handle_event/2]).
-export([
    start_term/1,
    start_object/1,
    start_array/1,
    finish/1,
    insert/2,
    get_key/1,
    get_value/1
]).


-record(config, {
    labels = binary
}).

-type config() :: list().
-export_type([config/0]).


-type json_value() :: list(json_value())
    | list({binary() | atom(), json_value()})
    | map()
    | true
    | false
    | null
    | integer()
    | float()
    | binary().


-spec to_term(Source::binary(), Config::config()) -> json_value().

to_term(Source, Config) when is_list(Config) ->
    (jsx:decoder(?MODULE, Config, jsx_config:extract_config(Config)))(Source).

parse_config(Config) -> parse_config(Config, #config{}).

parse_config([{labels, Val}|Rest], Config)
        when Val == binary; Val == atom; Val == existing_atom; Val == attempt_atom ->
    parse_config(Rest, Config#config{labels = Val});
parse_config([labels|Rest], Config) ->
    parse_config(Rest, Config#config{labels = binary});
parse_config([{K, _}|Rest] = Options, Config) ->
    case lists:member(K, jsx_config:valid_flags()) of
        true -> parse_config(Rest, Config)
        ; false -> erlang:error(badarg, [Options, Config])
    end;
parse_config([K|Rest] = Options, Config) ->
    case lists:member(K, jsx_config:valid_flags()) of
        true -> parse_config(Rest, Config)
        ; false -> erlang:error(badarg, [Options, Config])
    end;
parse_config([], Config) ->
    Config.


-type state() :: {list(), #config{}}.
-spec init(Config::proplists:proplist()) -> state().

init(Config) -> start_term(Config).

-spec handle_event(Event::any(), State::state()) -> state().

handle_event(end_json, State) -> get_value(State);

handle_event(start_object, State) -> start_object(State);
handle_event(end_object, State) -> finish(State);

handle_event(start_array, State) -> start_array(State);
handle_event(end_array, State) -> finish(State);

handle_event({key, Key}, {_, Config} = State) -> insert(format_key(Key, Config), State);

handle_event({_, Event}, State) -> insert(Event, State).


format_key(Key, Config) ->
    case Config#config.labels of
        binary -> Key
        ; atom -> binary_to_atom(Key, utf8)
        ; existing_atom -> binary_to_existing_atom(Key, utf8)
        ; attempt_atom ->
            try binary_to_existing_atom(Key, utf8) of
                Result -> Result
            catch
                error:badarg -> Key
            end
    end.


%% internal state is a stack and a config object
%%  `{Stack, Config}`
%% the stack is a list of in progress objects/arrays
%%  `[Current, Parent, Grandparent,...OriginalAncestor]`
%% an object has the representation on the stack of
%%  `{object, [
%%    {NthKey, NthValue},
%%    {NMinus1Key, NthMinus1Value},
%%    ...,
%%    {FirstKey, FirstValue}
%%  ]}`
%% or if returning maps
%%  `{object, #{
%%    FirstKey => FirstValue,
%%    SecondKey => SecondValue,
%%    ...,
%%    NthKey => NthValue
%%  }}`
%% or if there's a key with a yet to be matched value
%%  `{object, Key, ...}`
%% an array looks like
%%  `{array, [NthValue, NthMinus1Value,...FirstValue]}`

start_term(Config) when is_list(Config) -> {[], parse_config(Config)}.


%% allocate a new object on top of the stack
start_object({Stack, Config}) ->
    {[{object, []}] ++ Stack, Config}.


%% allocate a new array on top of the stack
start_array({Stack, Config}) -> {[{array, []}] ++ Stack, Config}.


%% finish an object or array and insert it into the parent object if it exists or
%% return it if it is the root object
finish({[{object, []}], Config}) -> {[{}], Config};
finish({[{object, []}|Rest], Config}) -> insert([{}], {Rest, Config});
finish({[{object, Pairs}], Config}) -> {lists:reverse(Pairs), Config};
finish({[{object, Pairs}|Rest], Config}) -> insert(lists:reverse(Pairs), {Rest, Config});
finish({[{array, Values}], Config}) -> {lists:reverse(Values), Config};
finish({[{array, Values}|Rest], Config}) -> insert(lists:reverse(Values), {Rest, Config});
finish(_) -> erlang:error(badarg).


%% insert a value when there's no parent object or array
insert(Value, {[], Config}) -> {Value, Config};
%% insert a key or value into an object or array, autodetects the 'right' thing
insert(Key, {[{object, Pairs}|Rest], Config}) ->
    {[{object, Key, Pairs}] ++ Rest, Config};
insert(Value, {[{object, Key, Pairs}|Rest], Config}) ->
    {[{object, [{Key, Value}] ++ Pairs}] ++ Rest, Config};
insert(Value, {[{array, Values}|Rest], Config}) ->
    {[{array, [Value] ++ Values}] ++ Rest, Config};
insert(_, _) -> erlang:error(badarg).


get_key({[{object, Key, _}|_], _}) -> Key;
get_key(_) -> erlang:error(badarg).


get_value({Value, _Config}) -> Value;
get_value(_) -> erlang:error(badarg).



%% eunit tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


config_test_() ->
    [
        {"empty config", ?_assertEqual(#config{}, parse_config([]))},
        {"implicit binary labels", ?_assertEqual(#config{}, parse_config([labels]))},
        {"binary labels", ?_assertEqual(#config{}, parse_config([{labels, binary}]))},
        {"atom labels", ?_assertEqual(#config{labels=atom}, parse_config([{labels, atom}]))},
        {"existing atom labels", ?_assertEqual(
            #config{labels=existing_atom},
            parse_config([{labels, existing_atom}])
        )},
        {"invalid opt flag", ?_assertError(badarg, parse_config([error]))},
        {"invalid opt tuple", ?_assertError(badarg, parse_config([{error, true}]))}
    ].


format_key_test_() ->
    [
        {"binary key", ?_assertEqual(<<"key">>, format_key(<<"key">>, #config{labels=binary}))},
        {"atom key", ?_assertEqual(key, format_key(<<"key">>, #config{labels=atom}))},
        {"existing atom key", ?_assertEqual(
            key,
            format_key(<<"key">>, #config{labels=existing_atom})
        )},
        {"nonexisting atom key", ?_assertError(
            badarg,
            format_key(<<"nonexistentatom">>, #config{labels=existing_atom})
        )},
        {"sloppy existing atom key", ?_assertEqual(
            key,
            format_key(<<"key">>, #config{labels=attempt_atom})
        )},
        {"nonexisting atom key", ?_assertEqual(
            <<"nonexistentatom">>,
            format_key(<<"nonexistentatom">>, #config{labels=attempt_atom})
        )}
    ].


rep_manipulation_test_() ->
    [
        {"allocate a new context with option", ?_assertEqual(
            {[], #config{labels=atom}},
            start_term([{labels, atom}])
        )},
        {"allocate a new object on an empty stack", ?_assertEqual(
            {[{object, []}], #config{}},
            start_object({[], #config{}})
        )},
        {"allocate a new object on a stack", ?_assertEqual(
            {[{object, []}, {object, []}], #config{}},
            start_object({[{object, []}], #config{}})
        )},
        {"allocate a new array on an empty stack", ?_assertEqual(
            {[{array, []}], #config{}},
            start_array({[], #config{}})
        )},
        {"allocate a new array on a stack", ?_assertEqual(
            {[{array, []}, {object, []}], #config{}},
            start_array({[{object, []}], #config{}})
        )},
        {"insert a key into an object", ?_assertEqual(
            {[{object, key, []}, junk], #config{}},
            insert(key, {[{object, []}, junk], #config{}})
        )},
        {"get current key", ?_assertEqual(
            key,
            get_key({[{object, key, []}], #config{}})
        )},
        {"try to get non-key from object", ?_assertError(
            badarg,
            get_key({[{object, []}], #config{}})
        )},
        {"try to get key from array", ?_assertError(
            badarg,
            get_key({[{array, []}], #config{}})
        )},
        {"insert a value into an object", ?_assertEqual(
            {[{object, [{key, value}]}, junk], #config{}},
            insert(value, {[{object, key, []}, junk], #config{}})
        )},
        {"insert a value into an array", ?_assertEqual(
            {[{array, [value]}, junk], #config{}},
            insert(value, {[{array, []}, junk], #config{}})
        )},
        {"finish an object with no ancestor", ?_assertEqual(
            {[{a, b}, {x, y}], #config{}},
            finish({[{object, [{x, y}, {a, b}]}], #config{}})
        )},
        {"finish an empty object", ?_assertEqual(
            {[{}], #config{}},
            finish({[{object, []}], #config{}})
        )},
        {"finish an object with an ancestor", ?_assertEqual(
            {[{object, [{key, [{a, b}, {x, y}]}, {foo, bar}]}], #config{}},
            finish({[{object, [{x, y}, {a, b}]}, {object, key, [{foo, bar}]}], #config{}})
        )},
        {"finish an array with no ancestor", ?_assertEqual(
            {[a, b, c], #config{}},
            finish({[{array, [c, b, a]}], #config{}})
        )},
        {"finish an array with an ancestor", ?_assertEqual(
            {[{array, [[a, b, c], d, e, f]}], #config{}},
            finish({[{array, [c, b, a]}, {array, [d, e, f]}], #config{}})
        )}
    ].


handle_event_test_() ->
    Data = test_cases(),
    [
        {
            Title, ?_assertEqual(
                Term,
                lists:foldl(fun handle_event/2, init([]), Events ++ [end_json])
            )
        } || {Title, _, Term, Events} <- Data
    ].


test_cases() ->
    empty_array()
    ++ nested_array()
    ++ empty_object()
    ++ nested_object()
    ++ strings()
    ++ literals()
    ++ integers()
    ++ floats()
    ++ compound_object().


empty_array() -> [{"[]", <<"[]">>, [], [start_array, end_array]}].


nested_array() ->
    [{
        "[[[]]]",
        <<"[[[]]]">>,
        [[[]]],
        [start_array, start_array, start_array, end_array, end_array, end_array]
    }].


empty_object() -> [{"{}", <<"{}">>, [{}], [start_object, end_object]}].


nested_object() ->
    [{
        "{\"key\":{\"key\":{}}}",
        <<"{\"key\":{\"key\":{}}}">>,
        [{<<"key">>, [{<<"key">>, [{}]}]}],
        [
            start_object,
                {key, <<"key">>},
                start_object,
                    {key, <<"key">>},
                    start_object,
                    end_object,
                end_object,
            end_object
        ]
    }].


naked_strings() ->
    Raw = [
        "",
        "hello world"
    ],
    [
        {
            String,
            <<"\"", (list_to_binary(String))/binary, "\"">>,
            list_to_binary(String),
            [{string, list_to_binary(String)}]
        }
        || String <- Raw
    ].


strings() ->
    naked_strings()
    ++ [ wrap_with_array(Test) || Test <- naked_strings() ]
    ++ [ wrap_with_object(Test) || Test <- naked_strings() ].


naked_integers() ->
    Raw = [
        1, 2, 3,
        127, 128, 129,
        255, 256, 257,
        65534, 65535, 65536,
        18446744073709551616,
        18446744073709551617
    ],
    [
        {
            integer_to_list(X),
            list_to_binary(integer_to_list(X)),
            X,
            [{integer, X}]
        }
        || X <- Raw ++ [ -1 * Y || Y <- Raw ] ++ [0]
    ].


integers() ->
    naked_integers()
    ++ [ wrap_with_array(Test) || Test <- naked_integers() ]
    ++ [ wrap_with_object(Test) || Test <- naked_integers() ].


naked_floats() ->
    Raw = [
        0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9,
        1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9,
        1234567890.0987654321,
        0.0e0,
        1234567890.0987654321e16,
        0.1e0, 0.1e1, 0.1e2, 0.1e4, 0.1e8, 0.1e16, 0.1e308,
        1.0e0, 1.0e1, 1.0e2, 1.0e4, 1.0e8, 1.0e16, 1.0e308,
        2.2250738585072014e-308,    %% min normalized float
        1.7976931348623157e308,     %% max normalized float
        5.0e-324,                   %% min denormalized float
        2.225073858507201e-308      %% max denormalized float
    ],
    [
        {
            sane_float_to_list(X),
            list_to_binary(sane_float_to_list(X)),
            X,
            [{float, X}]
        }
        || X <- Raw ++ [ -1 * Y || Y <- Raw ]
    ].


floats() ->
    naked_floats()
    ++ [ wrap_with_array(Test) || Test <- naked_floats() ]
    ++ [ wrap_with_object(Test) || Test <- naked_floats() ].


naked_literals() ->
    [
        {
            atom_to_list(Literal),
            atom_to_binary(Literal, unicode),
            Literal,
            [{literal, Literal}]
        }
        || Literal <- [true, false, null]
    ].


literals() ->
    naked_literals()
    ++ [ wrap_with_array(Test) || Test <- naked_literals() ]
    ++ [ wrap_with_object(Test) || Test <- naked_literals() ].


compound_object() ->
    [{
        "[{\"alpha\":[1,2,3],\"beta\":{\"alpha\":[1.0,2.0,3.0],\"beta\":[true,false]}},[{}]]",
        <<"[{\"alpha\":[1,2,3],\"beta\":{\"alpha\":[1.0,2.0,3.0],\"beta\":[true,false]}},[{}]]">>,
        [[{<<"alpha">>, [1, 2, 3]}, {<<"beta">>, [{<<"alpha">>, [1.0, 2.0, 3.0]}, {<<"beta">>, [true, false]}]}], [[{}]]],
        [
            start_array,
                start_object,
                    {key, <<"alpha">>},
                    start_array,
                        {integer, 1},
                        {integer, 2},
                        {integer, 3},
                    end_array,
                    {key, <<"beta">>},
                    start_object,
                        {key, <<"alpha">>},
                        start_array,
                            {float, 1.0},
                            {float, 2.0},
                            {float, 3.0},
                        end_array,
                        {key, <<"beta">>},
                        start_array,
                            {literal, true},
                            {literal, false},
                        end_array,
                    end_object,
                end_object,
                start_array,
                    start_object,
                    end_object,
                end_array,
            end_array
        ]
    }].


wrap_with_array({Title, JSON, Term, Events}) ->
    {
        "[" ++ Title ++ "]",
        <<"[", JSON/binary, "]">>,
        [Term],
        [start_array] ++ Events ++ [end_array]
    }.


wrap_with_object({Title, JSON, Term, Events}) ->
    {
        "{\"key\":" ++ Title ++ "}",
        <<"{\"key\":", JSON/binary, "}">>,
        [{<<"key">>, Term}],
        [start_object, {key, <<"key">>}] ++ Events ++ [end_object]
    }.

sane_float_to_list(X) ->
    [Output] = io_lib:format("~p", [X]),
    Output.

-endif.
