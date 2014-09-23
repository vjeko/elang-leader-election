-module(peer).
-define(ROUND_TIMEOUT_MIN, 5000).
-define(ROUND_TIMEOUT_MAX, 5200).

-define(VOTE_TIMEOUT, 500).
-define(KEEP_ALIVE_TIME, 250).
-define(MAX_ROUNDS, 2).

-define(BUG1, true).

-export([timer_test/2, initial/2, spawn_wait/0, setup_sync/1, concuerror_test/0]).


-record(peer_state,
    {
     pid = self() :: pid(),
     peers = [] :: [pid()],
     leader = none :: pid() | none,
     voted_for = none :: pid() | none,
     counter = none :: pid() | none, 
     round_timeout :: integer(),
     timer = none :: reference() | none,
     round = 0 :: integer(), 
     seed :: {integer(), integer(), integer()}
    }).


start_timer(State, Timeout, Message) ->
  State#peer_state{timer = erlang:start_timer(Timeout, self(), Message)}.


cancel_timer(S = #peer_state{timer = Timer}) ->
  case erlang:cancel_timer(Timer) of 
    false ->
      receive 
        {timeout, Timer, _} -> S#peer_state{timer=none}
        after 0 -> S#peer_state{timer=none}
      end;
    _ -> S#peer_state{timer=none}
  end.


%% Test timer functionality.
-spec(timer_test(integer(), boolean()) -> boolean()).
timer_test(Timeout, Cancel) ->
  S = #peer_state{}, 
  S2 = start_timer(S, Timeout, test),
  case Cancel of
    true -> cancel_timer(S2);
    false -> ok
  end,
  receive
    {timeout, _, test} -> not(Cancel)
    after 2*Timeout -> Cancel
  end.


reset_round_timeout(State = 
	#peer_state{round_timeout = Time, round = Round}) ->
  start_timer(State, Time, {round_timeout, Round}).


follower(State=#peer_state{timer=Timer, round=Round})
  	when Round =< ?MAX_ROUNDS ->
  receive
	{kill} -> ok;
    {leader, Leader, R} when R >= Round ->
      _S2 = cancel_timer(State),
      io:format("~p: ~p asserting leadership for round ~p~n", [self(), Leader, R]);
    {timeout, Timer, {round_timeout, R}} when R >= Round ->
      io:format("~p should start election now for round ~p~n", [self(), R]),
      election(#peer_state{round = R} = State);
    {request_vote, Counter, Pid, R} when R >= Round ->
      io:format("~p voting for ~p for round ~p~n", [self(), Pid, R]),
      S2 = cancel_timer(State),
      Counter ! {accept, Pid, R},
      wait(start_timer(#peer_state{voted_for = Pid, round = R} = S2,
                       ?VOTE_TIMEOUT,
                       {vote_timeout, R}));
    {request_vote, Counter, Pid, R} when R < Round ->
      io:format("~p not voting for ~p (stale round ~p)~n", [self(), Pid, R]),
      Counter ! {reject, Pid, R},
      follower(State)
  end;

follower(#peer_state{}) ->
  ok.


wait(State=#peer_state{timer=Timer, round=Round, voted_for=Voted})
  	when Round =< ?MAX_ROUNDS->
  receive
	{kill} -> ok;
    {timeout, Timer, {vote_timeout, Round}} ->
      io:format("~p election round expired ~p ~p~n", [self(), Voted, Round]), 
      follower(reset_round_timeout(State#peer_state{round=Round + 1, voted_for=none}));
    {leader, Leader, R} when R >= Round ->
      io:format("~p: ~p asserting leadership for round ~p~n", [self(), Leader, R]);
      %follower(reset_round_timeout(State#peer_state{round = R, leader = Leader, voted_for = none}));
    {leader, Leader, R} when R < Round ->
      io:format("~p: ~p asserting leadership for round ~p (Stale)~n", [self(), Leader, R]),
      wait(State);
    {request_vote, Counter, Pid, R} when R =< Round ->
      io:format("~p not voting for ~p (stale round ~p)~n", [self(), Pid, R]),
      Counter ! {reject, Pid, R},
      wait(State);
    {request_vote, Counter, Pid, R} when R > Round ->
      io:format("~p voting for ~p for round ~p~n", [self(), Pid, R]),
      S2 = cancel_timer(State),
      Counter ! {accept, Pid, R},
      wait(start_timer(
             #peer_state{voted_for = Pid, round = R} = S2,
             ?VOTE_TIMEOUT,
             {vote_timeout, R}))
  end;

wait(#peer_state{}) ->
  ok.


counter(Pid, Round, AcceptCount, _RejectCount, Quorum) 
	when AcceptCount >= Quorum ->
  receive 
    cancel -> ok
    after 0 ->  Pid ! {success, Round, AcceptCount}
  end;

counter(Pid, Round, AcceptCount, RejectCount, Quorum)
	when RejectCount >= Quorum ->
  receive 
    cancel -> ok
    after 0 ->  Pid ! {fail, Round, AcceptCount}
  end;

counter(Pid, Round, AcceptCount, RejectCount, Quorum) ->
  io:format("~p Counter is running for ~p ~n", [self(), Pid]),
  receive
    cancel ->
        io:format("~p (for ~p) cancelled ~n", [self(), Pid]);
    {accept, Pid, Round} ->
        io:format("~p for ~p received vote, quorum size is ~p (round ~p)~n", [self(), Pid, Quorum, Round]),
        counter(Pid, Round, AcceptCount + 1, RejectCount, Quorum);
    {reject, Pid, Round} ->
        io:format("~p for ~p received  no vote, quorum size is ~p (round ~p)~n", [self(), Pid, Quorum, Round]),
        counter(Pid, Round, AcceptCount, RejectCount + 1, Quorum)
  end.


spawn_counter(#peer_state{round = Round, peers = Peers}) ->
  Quorum = (length(Peers) div 2) + 1,
  Pid = self(),
  spawn_link(fun () -> counter(Pid, Round, 0, 0, Quorum) end).


election(State = #peer_state{round = Round, peers = Peers}) 
  	when Round =< ?MAX_ROUNDS ->
  Counter = spawn_counter(State),
  RequestVote = fun (P) -> P ! {request_vote, Counter, self(), Round} end,
  lists:map(RequestVote, Peers),
  wait_election(start_timer(#peer_state{counter = Counter} = State, 
							?VOTE_TIMEOUT, 
							{vote_timeout, Round}));


election(#peer_state{}) -> ok.


announce_leader(Pid, Round, #peer_state{peers=Peers}) ->
  lists:map(fun (P) -> P ! {leader, Pid, Round} end, Peers).


wait_election(State = 
	#peer_state{round = Round, counter = Counter, timer = Timer}) ->
  Pid = self(),
  receive
	  {kill} -> ok;
      {success, Round, Ct} -> 
        io:format("~p elected leader with ~p votes~n", [self(), Ct]),
        announce_leader(Pid, Round, State),
        receive
            {leader, Pid, Round} -> 
                io:format("~p announced leader with ~p votes (round ~p)~n", [self(), Ct, Round])
        end;
      {fail, Round, Ct} ->
        io:format("~p not elected leader with ~p votes (round ~p)~n", [self(), Ct, Round]),
        follower(reset_round_timeout(State#peer_state{round = Round + 1, leader = none, voted_for = none}));
      {leader, Leader, R} when R >= Round ->
        io:format("~p someone else ~p asserting leadership for round ~p~n", [self(), Leader, R]),
        Counter ! cancel;
        %follower(reset_round_timeout(State#peer_state{round = R, leader = Leader, voted_for = none}));
      {leader, Leader, R} when R < Round ->
        io:format("~p someone else ~p asserting leadership for round ~p (STALE) ~n", [self(), Leader, R]),
        wait_election(State);
      {request_vote, Counter, Pid, Round} ->
        io:format("~p Voting for self by sending to ~p (counter) ~p ~n", [self(), Counter, Round]),
        Counter ! {accept, Pid, Round},
        wait_election(State);
      {request_vote, Ctr, P, R} when R > Round ->
        cancel_timer(State),
        Counter ! cancel,
        receive
         _ -> ok
         after 0 -> ok
        end,
        io:format("~p voting for ~p for round ~p~n", [self(), Pid, R]),
        Ctr ! {accept, P, R},
        wait(start_timer(
               State#peer_state{voted_for=Pid, round = R, counter = none},
               ?VOTE_TIMEOUT,
               {vote_timeout, R}));
      {request_vote, Ctr, P2, R} ->
		case ?BUG1 of
          false ->
              Ctr ! {reject, P2, R},
              wait_election(State);
		  _ ->
			  exit(bug1)
		end;
      {timeout, Timer, {vote_timeout, Round}} ->
        io:format("~p Things did not work out, stopping election for round ~p~n", [self(), Round]),
        Counter ! cancel,
        receive
         _ -> ok
         after 0 -> ok
        end,
        follower(reset_round_timeout(State#peer_state{round = Round + 1}))
  end.


-spec(initial({integer(), integer(), integer()}, #peer_state{}) -> #peer_state{}).
initial(Seed, Peers) ->
  random:seed(Seed),
  RoundTime =  random:uniform(?ROUND_TIMEOUT_MAX - ?ROUND_TIMEOUT_MIN) + ?ROUND_TIMEOUT_MIN,
  io:format("~p selecting round timeout at ~p~n", [self(), RoundTime]),
  #peer_state{peers = Peers, seed = Seed, round_timeout = RoundTime}.


-spec(wait(none()) -> none()).
spawn_wait () ->
    io:format("Now waiting~n"),
    receive
        {start, Seed, Peers} -> 
            io:format("Received start signal~n"),
            State = initial(Seed, Peers),
            S2 = reset_round_timeout(State),
            follower(S2);
        M ->
          io:format("~p [Peer-Internal] Received something else ~p ~n", [self(), M]),
          spawn_wait()
    end.



-spec(setup_sync(integer()) -> none()).
setup_sync (N) ->
  Seeds = [{X * 13, X * 7, X + 1} || X <- lists:seq(1, N)],
  Peers = [spawn_link(fun spawn_wait/0) || _ <- lists:seq(1, N)],
  Args = [{start, Seed, Peers} || Seed <- Seeds],
  io:format("Opening flood gates~n"),
  lists:zipwith(fun (Peer, Arg) -> Peer ! Arg end, Peers, Args),

  Master = spawn_link(fun master/0),
  Master ! {start, Peers},

  ok.


-spec(master() -> none()).
master() ->
    io:format("spawning the master~n"),
    receive
        {start, Peers} -> 
            io:format("time to kill some nodes..."),
			NumPeers = length(Peers) div 2 - 1,
			{List1, _} = lists:split(NumPeers, Peers),
			Fun = fun (Peer) -> Peer ! {kill} end,
		    lists:map(Fun, List1);
        M ->
          io:format("~p [Peer-Internal] Received something else ~p ~n", [self(), M]),
          master()
    end.

-spec(concuerror_test() -> none()).
concuerror_test() ->
  io:format("~p starting thing~n", [self()]),
  setup_sync(7).
