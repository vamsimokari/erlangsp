-module(esp_cache_SUITE).

-include("../../erlangsp/include/license_and_copyright.hrl").
-include_lib("common_test/include/ct.hrl").
-include("../../coop/include/coop_dag.hrl").
-include("../../examples/esp_cache/include/esp_cache.hrl").

%% Suite functions
-export([all/0, init_per_suite/1, end_per_suite/1]).

%% Test Coop Node functionality individually
-export([datum_value/1,
         worker_value/1, worker_mfa/1, worker_replace/1
        ]).

%% Spawned functions must be exported
-export([check_worker/2, compute_value/1]).

all() -> [
          datum_value,
          worker_value, worker_mfa, worker_replace
         ].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.


%%----------------------------------------------------------------------
%% Coop Node tests
%%----------------------------------------------------------------------
datum_value(_Config) ->

    %% Get original value...
    Kill_Switch = coop_kill_link_rcv:make_kill_switch(),
    {coop_node, _Node_Ctl_Pid, Node_Task_Pid} = Coop_Node
        = esp_cache:new_datum_node(Kill_Switch, 17),
    R1 = make_ref(),
    coop:relay_data(Coop_Node, {get_value, {R1, self()}}),
    17 = check_datum(R1),
    R2 = make_ref(),
    coop:relay_data(Coop_Node, {get_value, {R2, self()}}),
    17 = check_datum(R2),
    
    %% Replace value and get new value...
    R3 = make_ref(),
    coop:relay_data(Coop_Node, {replace, 23, {R3, self()}}),
    23 = check_datum(R3),
    R4 = make_ref(),
    coop:relay_data(Coop_Node, {get_value, {R4, self()}}),
    23 = check_datum(R4),
    
    %% Check for expiration...
    erlang:monitor(process, Node_Task_Pid),
    coop:relay_data(Coop_Node, {expire, {foo, self()}}),
    {exited, _Pid} = check_datum(foo).

check_datum(Ref) ->
    receive
        {Ref, Value} -> Value;
        {'DOWN', _MRef, process, Pid, normal} -> {exited, Pid}
    after 1000 -> timeout
    end.

worker_test_age(Value_Expr, Answer) ->

    %% Create a worker node...
    Self = self(),
    meck:new(coop, [passthrough]),
    meck:expect(coop, get_kill_switch, fun(_Coop_Head) -> Self end),
    Fake_Coop_Head = {coop_head, Self, Self},
    {coop_node, _Node_Ctl_Pid, _Node_Task_Pid} = Coop_Node
        = esp_cache:new_worker_node(Fake_Coop_Head),
    ?CTL_MSG({link, _Pids1}) = receive A -> A after 1000 -> timeout end,

    %% Create a new cached datum node from the value expression...
    R1 = make_ref(),
    Rcvr = proc_lib:spawn_link(?MODULE, check_worker, [R1, []]),
    coop:relay_data(Coop_Node, {add, {age, Value_Expr, {R1, Rcvr}}}),
    Results = check_worker([]),
    2 = length(Results),
    [?CTL_MSG({link, _Pids2})] = [I || I <- Results, element(1,element(3, I)) =:= link],
    [?DATA_MSG({new, age, {coop_node, _, _}})]
        = [I || I <- Results, element(1, element(3, I)) =:= new],
    timer:sleep(50),
    Rcvr ! {results, Self},
    [[Answer]] = check_worker([]),
    meck:unload(coop).

check_worker(Acc) ->
    receive Any -> check_worker([Any | Acc])
    after 100   -> lists:reverse(Acc)
    end.
check_worker(Ref, Acc) ->
    receive
        {Ref, Value} -> check_worker(Ref, [Value | Acc]);
        {results, From} -> From ! lists:reverse(Acc)
    after 5000 -> no_msg
    end.

compute_value(X) -> 3*X.

worker_value(_Config) -> worker_test_age({?VALUE, 15}, 15).
worker_mfa(_Config)   -> worker_test_age({?MFA, {?MODULE, compute_value, 7}}, 21).
    
worker_replace(_Config) ->

    %% Create a worker node...
    Self = self(),
    meck:new(coop, [passthrough]),
    meck:expect(coop, get_kill_switch, fun(_Coop_Head) -> Self end),
    Fake_Coop_Head = {coop_head, Self, Self},
    {coop_node, _Node_Ctl_Pid, _Node_Task_Pid} = Coop_Node
        = esp_cache:new_worker_node(Fake_Coop_Head),
    ?CTL_MSG({link, _Pids1}) = receive A -> A after 1000 -> timeout end,

    %% Create a new cached datum node from a simple value...
    R1 = make_ref(),
    Rcvr = proc_lib:spawn_link(?MODULE, check_worker, [R1, []]),
    coop:relay_data(Coop_Node, {add, {age, {?VALUE, 37}, {R1, Rcvr}}}),
    Results = check_worker([]),
    2 = length(Results),
    [?CTL_MSG({link, _Pids2})] = [I || I <- Results, element(1,element(3, I)) =:= link],
    [?DATA_MSG({new, age, {coop_node, _, _} = New_Datum_Cache_Node})]
        = [I || I <- Results, element(1, element(3, I)) =:= new],
    timer:sleep(50),
    Rcvr ! {results, Self},
    [[37]] = check_worker([]),

    %% Replace the cached datum value...
    R2 = make_ref(),
    Rcvr2 = proc_lib:spawn_link(?MODULE, check_worker, [R2, []]),
    coop:relay_data(Coop_Node, {replace, {age, {?MFA, {?MODULE, compute_value, 11}}, {R2, Rcvr2}},
                                New_Datum_Cache_Node}),
    timer:sleep(50),
    Rcvr2 ! {results, Self},
    [[33]] = check_worker([]),
    meck:unload(coop).
