%%% @doc Import verified AO token payments into a local HyperBEAM payment
%%% ledger. This device expects production AO token transfers of the form:
%%%
%%%     Action=Transfer, Recipient=node-deposit-address, Quantity=raw-units
%%%
%%% It verifies the resulting `Debit-Notice' and `Credit-Notice' from AO
%%% mainnet state before scheduling a local `Credit-Notice' into the configured
%%% ledger process.
-module(dev_aopayment).
-implements(<<"ao-payment@1.11">>).
-export([device_info/0, ingest/3, verify/3, withdraw/3, balance/3, charge/3]).
-include_lib("hb/include/hb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(DEFAULT_AO_TOKEN, <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>).
-define(DEFAULT_MAINNET_URL, <<"https://state.forward.computer">>).
-define(DEFAULT_SUBMIT_URL, <<"https://mu.ao-testnet.xyz">>).
-define(HTTP_TIMEOUT_MS, 30000).
-define(DEFAULT_SETTLEMENT_TIMEOUT_MS, 300000).
-define(DEFAULT_SETTLEMENT_POLL_MS, 3000).
-define(DEFAULT_RESERVATION_TTL_MS, 3600000).
-define(LEDGER_READ_ATTEMPTS, 3).
-define(LEDGER_READ_RETRY_MS, 10).
-define(STATE_TERM_TAG, dev_aopayment_state_v1).

%% @doc Public AO payment operations exposed to the resolver.
device_info() ->
    #{exports => [<<"ingest">>, <<"verify">>, <<"withdraw">>,
        <<"balance">>, <<"charge">>]}.

%% @doc Verify and import an AO token payment into the local ledger.
ingest(Base, Req, NodeMsg) ->
    case verify(Base, Req, NodeMsg) of
        {ok, Payment} ->
            PaymentKey = payment_key(Payment),
            with_payment_lock(
                PaymentKey,
                fun() -> ingest_verified_payment(PaymentKey, Payment, NodeMsg) end
            );
        Error ->
            Error
    end.

ingest_verified_payment(PaymentKey, Payment, NodeMsg) ->
    case load_import(PaymentKey, NodeMsg) of
        {ok, Existing} ->
            case payment_status(Existing) of
                <<"prepared">> ->
                    settle_import(PaymentKey, Existing, NodeMsg);
                <<"scheduled">> ->
                    settle_import(PaymentKey, Existing, NodeMsg);
                <<"imported">> ->
                    {ok, Existing#{ <<"status">> => <<"already-imported">> }};
                <<"already-imported">> ->
                    {ok, Existing};
                _ ->
                    {ok, Existing#{ <<"status">> => <<"already-imported">> }}
            end;
        not_found ->
            case prepare_payment_import(Payment, NodeMsg) of
                {ok, PendingPayment} ->
                    case store_import(PaymentKey, PendingPayment, NodeMsg) of
                        ok ->
                            schedule_new_import(
                                PaymentKey,
                                PendingPayment,
                                NodeMsg
                            );
                        {error, Reason} ->
                            payment_import_error(
                                500,
                                <<"Unable to persist AO payment import before scheduling.">>,
                                Reason
                            )
                    end;
                Error ->
                    Error
            end;
        {error, Reason} ->
            payment_import_error(
                500,
                <<"Unable to read AO payment import state.">>,
                Reason
            )
    end.

%% @doc Submit a real AO transfer from the node wallet to the configured
%% beneficiary. This is guarded by either a boot-generated secret or a verified
%% operator-signed request so the route is not an arbitrary signing endpoint
%% when exposed over HTTP.
withdraw(Base, Req, NodeMsg) ->
    case validate_withdrawal(Base, Req, NodeMsg) of
        {ok, Withdrawal} ->
            Key = withdrawal_key(Withdrawal),
            with_withdrawal_lock(
                Key,
                fun() -> submit_and_store_withdrawal(Key, Withdrawal, NodeMsg) end
            );
        Error ->
            Error
    end.

%% @doc P4 ledger API: read the requester or explicit target balance from the
%% configured local AO payment ledger.
balance(Base, Req, NodeMsg) ->
    case {ledger_path(Base, NodeMsg), balance_target(Req, NodeMsg)} of
        {undefined, _} ->
            payment_import_error(
                500,
                <<"Missing AO payment ledger path.">>,
                missing_ledger_path
            );
        {_, undefined} ->
            {ok, 0};
        {LedgerPath, Target} ->
            balance_with_reservation(Base, LedgerPath, Target, Req, NodeMsg)
    end.

%% @doc P4 ledger API: apply a node-signed p4 charge to the local AO payment
%% ledger process.
charge(Base, Req, NodeMsg) ->
    case ledger_path(Base, NodeMsg) of
        undefined ->
            payment_import_error(
                500,
                <<"Missing AO payment ledger path.">>,
                missing_ledger_path
            );
        LedgerPath ->
            case validate_charge_request(Base, Req, NodeMsg) of
                {ok, Account, Recipient, Quantity} ->
                    with_account_lock(
                        LedgerPath,
                        Account,
                        fun() ->
                            charge_locked(
                                Base,
                                Req,
                                LedgerPath,
                                Account,
                                Recipient,
                                Quantity,
                                NodeMsg
                            )
                        end
                    );
                Error ->
                    Error
            end
    end.

charge_locked(Base, Req, LedgerPath, Account, Recipient, Quantity, NodeMsg) ->
    LedgerOpts = ledger_resolve_opts(NodeMsg),
    Request = direct_get(<<"request">>, Req),
    ReservationKey = request_key(Request, NodeMsg),
    case reservation_for(Account, ReservationKey, NodeMsg) of
        {error, _} = Error ->
            Error;
        {ok, Reservation, ReservationState} ->
            Reserved = hb_maps:get(<<"amount">>, Reservation, 0, NodeMsg),
            case Quantity =< Reserved of
                false ->
                    {error, #{
                        <<"status">> => 402,
                        <<"body">> => <<"Measured charge exceeds the reserved maximum.">>,
                        <<"price">> => Quantity,
                        <<"reserved">> => Reserved
                    }};
                true ->
                    charge_sufficient_balance(
                        Base,
                        Req,
                        LedgerPath,
                        Account,
                        Recipient,
                        Quantity,
                        ReservationKey,
                        ReservationState,
                        LedgerOpts,
                        NodeMsg
                    )
            end;
        {terminal, #{ <<"status">> := <<"charged">> } = Reservation, _State} ->
            case prepared_charge_matches(Reservation, Req, Account, Quantity, NodeMsg) of
                true ->
                    {ok, #{
                        <<"status">> => <<"already-charged">>,
                        <<"quantity">> => Quantity
                    }};
                false ->
                    withdraw_error(
                        409,
                        <<"AO payment charge conflicts with the completed reservation.">>
                    )
            end;
        {terminal, #{ <<"status">> := <<"charging">> } = Reservation, State} ->
            resume_prepared_charge(
                Req,
                LedgerPath,
                Account,
                Recipient,
                Quantity,
                ReservationKey,
                Reservation,
                State,
                NodeMsg
            );
        {terminal, #{ <<"status">> := <<"released">> }, _State} ->
            withdraw_error(409, <<"AO payment reservation was already released.">>);
        not_found ->
            case reservation_amount(Base, NodeMsg) > 0 of
                true ->
                    withdraw_error(402, <<"AO payment charge has no active reservation.">>);
                false ->
                    charge_sufficient_balance(
                        Base,
                        Req,
                        LedgerPath,
                        Account,
                        Recipient,
                        Quantity,
                        undefined,
                        undefined,
                        LedgerOpts,
                        NodeMsg
                    )
            end
    end.

charge_sufficient_balance(
    Base,
    Req,
    LedgerPath,
    Account,
    Recipient,
    Quantity,
    ReservationKey,
    ReservationState,
    LedgerOpts,
    NodeMsg
) ->
    case read_p4_ledger_balance_at(LedgerPath, Account, LedgerOpts) of
        {ok, PayerBalance} when PayerBalance >= Quantity ->
            apply_reserved_charge(
                Base,
                Req,
                LedgerPath,
                Account,
                Recipient,
                Quantity,
                ReservationKey,
                ReservationState,
                LedgerOpts,
                PayerBalance,
                NodeMsg
            );
        {ok, Balance} ->
            {error, #{
                <<"status">> => 402,
                <<"body">> => <<"Insufficient funds">>,
                <<"balance">> => Balance,
                <<"price">> => Quantity
            }};
        Error ->
            Error
    end.

apply_reserved_charge(
    Base,
    Req,
    LedgerPath,
    _Account,
    _Recipient,
    _Quantity,
    undefined,
    _ReservationState,
    _LedgerOpts,
    _PayerBalance,
    NodeMsg
) ->
    apply_charge(Base, Req, LedgerPath, NodeMsg);
apply_reserved_charge(
    Base,
    Req,
    LedgerPath,
    Account,
    Recipient,
    Quantity,
    ReservationKey,
    ReservationState,
    LedgerOpts,
    PayerBalance,
    NodeMsg
) ->
    case read_p4_ledger_balance_at(LedgerPath, Recipient, LedgerOpts) of
        {ok, RecipientBalance} ->
            LedgerCharge = ledger_charge_request(Req, NodeMsg),
            case mark_reservation_charging(
                Account,
                Recipient,
                Quantity,
                ReservationKey,
                LedgerCharge,
                PayerBalance,
                RecipientBalance,
                ReservationState,
                NodeMsg
            ) of
                {ok, ChargingState} ->
                    complete_prepared_charge(
                        Base,
                        LedgerPath,
                        Account,
                        Quantity,
                        ReservationKey,
                        LedgerCharge,
                        ChargingState,
                        NodeMsg
                    );
                {error, Reason} ->
                    payment_import_error(
                        500,
                        <<"Unable to persist AO payment charge intent.">>,
                        Reason
                    )
            end;
        Error ->
            Error
    end.

resume_prepared_charge(
    Req,
    LedgerPath,
    Account,
    Recipient,
    Quantity,
    ReservationKey,
    Reservation,
    State,
    NodeMsg
) ->
    case prepared_charge_matches(Reservation, Req, Account, Quantity, NodeMsg) of
        true ->
            reconcile_prepared_charge(
                LedgerPath,
                Account,
                Recipient,
                Quantity,
                ReservationKey,
                Reservation,
                State,
                NodeMsg
            );
        false ->
            withdraw_error(
                409,
                <<"AO payment charge conflicts with the in-flight reservation.">>
            )
    end.

reconcile_prepared_charge(
    LedgerPath,
    Account,
    Recipient,
    Quantity,
    ReservationKey,
    Reservation,
    State,
    NodeMsg
) ->
    LedgerOpts = ledger_resolve_opts(NodeMsg),
    case read_p4_ledger_balance_at(LedgerPath, Account, LedgerOpts) of
        {ok, PayerBalance} ->
            case read_p4_ledger_balance_at(LedgerPath, Recipient, LedgerOpts) of
                {ok, RecipientBalance} ->
                    case charge_was_applied(
                        Account,
                        Recipient,
                        Quantity,
                        PayerBalance,
                        RecipientBalance,
                        Reservation,
                        NodeMsg
                    ) of
                        true ->
                            case consume_reservation(
                                Account,
                                ReservationKey,
                                Quantity,
                                State,
                                NodeMsg
                            ) of
                                ok ->
                                    {ok, #{
                                        <<"status">> => <<"already-charged">>,
                                        <<"quantity">> => Quantity
                                    }};
                                {error, Reason} ->
                                    payment_import_error(
                                        500,
                                        <<"Reconciled charge state could not be committed.">>,
                                        Reason
                                    )
                            end;
                        false ->
                            {error, #{
                                <<"status">> => 503,
                                <<"body">> =>
                                    <<"AO payment charge outcome is uncertain; automatic resubmission is disabled.">>,
                                <<"payer-balance">> => PayerBalance,
                                <<"recipient-balance">> => RecipientBalance
                            }}
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

charge_was_applied(
    Account,
    Recipient,
    Quantity,
    PayerBalance,
    RecipientBalance,
    Reservation,
    NodeMsg
) ->
    BeforePayer = hb_maps:get(<<"payer-balance-before">>, Reservation, undefined, NodeMsg),
    BeforeRecipient =
        hb_maps:get(<<"recipient-balance-before">>, Reservation, undefined, NodeMsg),
    Account =/= Recipient
        andalso is_integer(BeforePayer)
        andalso is_integer(BeforeRecipient)
        andalso PayerBalance =:= BeforePayer - Quantity
        andalso RecipientBalance >= BeforeRecipient + Quantity.

prepared_charge_matches(Reservation, Req, Account, Quantity, NodeMsg) ->
    LedgerCharge = hb_maps:get(
        <<"ledger-charge">>,
        Reservation,
        undefined,
        NodeMsg
    ),
    RequestedRecipient = normalize_target(direct_get(<<"recipient">>, Req)),
    try
        is_map(LedgerCharge)
            andalso hb_util:int(
                hb_maps:get(<<"quantity">>, Reservation, undefined, NodeMsg)
            ) =:= Quantity
            andalso normalize_target(direct_get(<<"account">>, LedgerCharge)) =:= Account
            andalso normalize_target(direct_get(<<"recipient">>, LedgerCharge)) =:=
                RequestedRecipient
            andalso hb_util:int(direct_get(<<"quantity">>, LedgerCharge)) =:= Quantity
    catch
        _:_ -> false
    end.

complete_prepared_charge(
    Base,
    LedgerPath,
    Account,
    Quantity,
    ReservationKey,
    LedgerCharge,
    State,
    NodeMsg
) ->
    case apply_ledger_charge(Base, LedgerPath, LedgerCharge, NodeMsg) of
        {ok, _} = Success ->
            case consume_reservation(
                Account,
                ReservationKey,
                Quantity,
                State,
                NodeMsg
            ) of
                ok -> Success;
                {error, Reason} ->
                    payment_import_error(
                        500,
                        <<"Charge succeeded but reservation state could not be committed.">>,
                        Reason
                    )
            end;
        Error ->
            payment_import_error(
                503,
                <<"AO payment charge outcome is uncertain; automatic resubmission is disabled.">>,
                Error
            )
    end.

apply_charge(Base, Req, LedgerPath, NodeMsg) ->
    case auto_withdraw_enabled(Base, NodeMsg) of
        true ->
            unsafe_auto_withdraw_error();
        false ->
            apply_ledger_charge(
                Base,
                LedgerPath,
                ledger_charge_request(Req, NodeMsg),
                NodeMsg
            )
    end.

apply_ledger_charge(Base, LedgerPath, LedgerCharge, NodeMsg) ->
    case auto_withdraw_enabled(Base, NodeMsg) of
        true ->
            unsafe_auto_withdraw_error();
        false ->
            LedgerRoute = normalize_route(LedgerPath),
            LedgerOpts = ledger_resolve_opts(NodeMsg),
            hb_ao:resolve(
                #{
                    <<"path">> => <<"(", LedgerRoute/binary, ")/push">>,
                    <<"method">> => <<"POST">>,
                    <<"body">> => LedgerCharge
                },
                LedgerOpts
            )
    end.

unsafe_auto_withdraw_error() ->
    payment_import_error(
        500,
        <<"AO payment auto-withdraw is disabled because submission is not settlement. Configure deposits to the beneficiary and set auto-withdraw=false.">>,
        unsafe_auto_withdraw_configuration
    ).

ledger_charge_request(Req, NodeMsg) ->
    Account = normalize_target(direct_get(<<"account">>, Req)),
    Recipient = normalize_target(direct_get(<<"recipient">>, Req)),
    Quantity = hb_util:int(direct_get(<<"quantity">>, Req)),
    hb_message:commit(
        #{
            <<"path">> => <<"charge">>,
            <<"account">> => Account,
            <<"recipient">> => Recipient,
            <<"quantity">> => Quantity
        },
        wallet_opts(NodeMsg)
    ).

with_account_lock(LedgerPath, Account, Fun) ->
    Lock = {{?MODULE, node(), normalize_route(LedgerPath), Account}, self()},
    case global:trans(Lock, Fun) of
        aborted ->
            payment_import_error(
                503,
                <<"Unable to acquire AO payment ledger charge lock.">>,
                charge_lock_aborted
            );
        Result ->
            Result
    end.

validate_charge_request(Base, Req, NodeMsg) ->
    Account = normalize_target(direct_get(<<"account">>, Req)),
    Recipient = normalize_target(direct_get(<<"recipient">>, Req)),
    Quantity0 = direct_get(<<"quantity">>, Req),
    Allowed = withdraw_authorized_signers(Base, NodeMsg),
    Signers = verified_message_signers(Req, NodeMsg),
    ChargeRecipients = configured_charge_recipients(NodeMsg),
    case {
        Account,
        Recipient,
        parse_positive_quantity(Quantity0),
        [Signer || Signer <- Signers, lists:member(Signer, Allowed)],
        lists:member(Recipient, ChargeRecipients),
        ChargeRecipients
    } of
        {undefined, _, _, _, _, _} ->
            withdraw_error(400, <<"AO payment charge is missing a single payer account.">>);
        {_, undefined, _, _, _, _} ->
            withdraw_error(400, <<"AO payment charge is missing a single recipient.">>);
        {_, _, {error, _}, _, _, _} ->
            withdraw_error(400, <<"AO payment charge has an invalid quantity.">>);
        {_, _, _, _, _, []} ->
            payment_import_error(
                500,
                <<"AO payment charge recipient is not configured.">>,
                missing_charge_recipient
            );
        {_, _, _, [], _, _} ->
            withdraw_error(403, <<"AO payment charge is not signed by the operator.">>);
        {_, _, _, _, false, _} ->
            withdraw_error(
                403,
                <<"AO payment charge recipient does not match configured p4 recipient.">>
            );
        {ValidAccount, ValidRecipient, {ok, Quantity}, [_ | _], true, _} ->
            {ok, ValidAccount, ValidRecipient, Quantity}
    end.

balance_with_reservation(Base, LedgerPath, Account, Req, NodeMsg) ->
    with_account_lock(
        LedgerPath,
        Account,
        fun() ->
            case read_p4_ledger_balance_at(
                LedgerPath,
                Account,
                ledger_resolve_opts(NodeMsg)
            ) of
                {ok, Balance} ->
                    reserve_balance(Base, Account, Balance, Req, NodeMsg);
                Error ->
                    Error
            end
        end
    ).

reserve_balance(Base, Account, Balance, Req, NodeMsg) ->
    case load_reservations(Account, NodeMsg) of
        {ok, State0} ->
            {State, StateChanged} = prune_expired_reservations(State0),
            Available = erlang:max(0, Balance - reserved_total(State)),
            case reservation_request(Account, Req, NodeMsg) of
                none ->
                    maybe_store_pruned_reservations(
                        Account,
                        State,
                        StateChanged,
                        {ok, Available},
                        NodeMsg
                    );
                {ok, Key} ->
                    reserve_request(
                        Base,
                        Account,
                        Key,
                        Available,
                        State,
                        StateChanged,
                        NodeMsg
                    );
                invalid ->
                    maybe_store_pruned_reservations(
                        Account,
                        State,
                        StateChanged,
                        {ok, 0},
                        NodeMsg
                    )
            end;
        {error, Reason} ->
            payment_import_error(
                500,
                <<"Unable to read AO payment reservation state.">>,
                Reason
            )
    end.

reserve_request(Base, Account, Key, Available, State, StateChanged, NodeMsg) ->
    case maps:find(Key, State) of
        {ok, #{ <<"status">> := <<"reserved">> }} ->
            maybe_store_pruned_reservations(
                Account,
                State,
                StateChanged,
                {ok, 0},
                NodeMsg
            );
        {ok, _Terminal} ->
            maybe_store_pruned_reservations(
                Account,
                State,
                StateChanged,
                {ok, 0},
                NodeMsg
            );
        error ->
            Amount = reservation_amount(Base, NodeMsg),
            case Amount > 0 andalso Available >= Amount of
                true ->
                    Now = erlang:system_time(millisecond),
                    Entry = #{
                        <<"status">> => <<"reserved">>,
                        <<"amount">> => Amount,
                        <<"created-at">> => Now,
                        <<"expires-at">> => Now + reservation_ttl_ms(NodeMsg)
                    },
                    case store_reservations(Account, State#{ Key => Entry }, NodeMsg) of
                        ok -> {ok, true};
                        {error, Reason} ->
                            payment_import_error(
                                500,
                                <<"Unable to persist AO payment reservation.">>,
                                Reason
                            )
                    end;
                false ->
                    maybe_store_pruned_reservations(
                        Account,
                        State,
                        StateChanged,
                        {ok, 0},
                        NodeMsg
                    )
            end
    end.

reservation_request(Account, Req, NodeMsg) ->
    case normalize_target(direct_get(<<"target">>, Req)) of
        undefined ->
            %% p4@1.0's public balance handler nests the signed query but does
            %% not set an outer target. Only its priced request admission path
            %% supplies both target and request.
            none;
        Account ->
            reservation_request_for_target(Account, Req, NodeMsg);
        _OtherTarget ->
            invalid
    end.

reservation_request_for_target(Account, Req, NodeMsg) ->
    case direct_get(<<"request">>, Req) of
        Request when is_map(Request) ->
            case verified_message_signers(Request, NodeMsg) of
                [Account] ->
                    case request_key(Request, NodeMsg) of
                        undefined -> invalid;
                        Key -> {ok, Key}
                    end;
                _ ->
                    invalid
            end;
        _ ->
            invalid
    end.

request_key(undefined, _NodeMsg) ->
    undefined;
request_key({link, ID, _LinkOpts}, _NodeMsg) ->
    normalize_target(ID);
request_key(Request, NodeMsg) when is_map(Request) ->
    try hb_util:human_id(hb_message:id(Request, signed, NodeMsg))
    catch
        _:_ -> undefined
    end;
request_key(_, _NodeMsg) ->
    undefined.

reservation_for(_Account, undefined, _NodeMsg) ->
    not_found;
reservation_for(Account, Key, NodeMsg) ->
    case load_reservations(Account, NodeMsg) of
        {ok, State0} ->
            {State, Changed} = prune_expired_reservations(State0),
            case persist_pruned_reservations(Account, State, Changed, NodeMsg) of
                ok ->
                    case maps:find(Key, State) of
                        {ok, #{ <<"status">> := <<"reserved">> } = Reservation} ->
                            {ok, Reservation, State};
                        {ok, Terminal} ->
                            {terminal, Terminal, State};
                        error ->
                            not_found
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

mark_reservation_charging(
    Account,
    Recipient,
    Quantity,
    Key,
    LedgerCharge,
    PayerBalance,
    RecipientBalance,
    State,
    NodeMsg
) ->
    Now = erlang:system_time(millisecond),
    Entry0 = maps:get(Key, State),
    Entry = Entry0#{
        <<"status">> => <<"charging">>,
        <<"quantity">> => Quantity,
        <<"recipient">> => Recipient,
        <<"payer-balance-before">> => PayerBalance,
        <<"recipient-balance-before">> => RecipientBalance,
        <<"ledger-charge">> => LedgerCharge,
        <<"charging-at">> => Now
    },
    NewState = State#{ Key => Entry },
    case store_reservations(Account, NewState, NodeMsg) of
        ok -> {ok, NewState};
        Error -> Error
    end.

consume_reservation(Account, Key, Quantity, State, NodeMsg) ->
    Entry0 = maps:get(Key, State),
    Entry = Entry0#{
        <<"status">> => <<"charged">>,
        <<"quantity">> => Quantity,
        <<"charged-at">> => erlang:system_time(millisecond)
    },
    case store_reservations(Account, State#{ Key => Entry }, NodeMsg) of
        ok -> ok;
        Error ->
            Error
    end.

reserved_total(State) ->
    maps:fold(
        fun(_Key, Entry, Acc) ->
            case hb_maps:get(<<"status">>, Entry, undefined, #{}) of
                <<"reserved">> -> Acc + hb_maps:get(<<"amount">>, Entry, 0, #{});
                <<"charging">> -> Acc + hb_maps:get(<<"amount">>, Entry, 0, #{});
                _ -> Acc
            end
        end,
        0,
        State
    ).

prune_expired_reservations(State) ->
    Now = erlang:system_time(millisecond),
    NewState = maps:filter(
        fun(_Key, Entry) ->
            Status = hb_maps:get(<<"status">>, Entry, undefined, #{}),
            Expires = hb_maps:get(<<"expires-at">>, Entry, 0, #{}),
            Status =/= <<"reserved">> orelse Expires > Now
        end,
        State
    ),
    {NewState, NewState =/= State}.

maybe_store_pruned_reservations(Account, State, Changed, Result, NodeMsg) ->
    case persist_pruned_reservations(Account, State, Changed, NodeMsg) of
        ok -> Result;
        {error, Reason} ->
            payment_import_error(
                500,
                <<"Unable to persist AO payment reservation state.">>,
                Reason
            )
    end.

persist_pruned_reservations(_Account, _State, false, _NodeMsg) ->
    ok;
persist_pruned_reservations(Account, State, true, NodeMsg) ->
    store_reservations(Account, State, NodeMsg).

load_reservations(Account, NodeMsg) ->
    persistent_state_read(reservations_path(Account, NodeMsg), #{}, NodeMsg).

store_reservations(Account, State, NodeMsg) ->
    persistent_state_write(reservations_path(Account, NodeMsg), State, NodeMsg).

reservations_path(Account, NodeMsg) ->
    state_path(
        <<"reservations">>,
        {normalize_route(configured_ledger_path(NodeMsg)), Account}
    ).

reservation_amount(_Base, NodeMsg) ->
    Value = configured_value(
        <<"ao-payment-reservation-amount">>,
        ao_payment_reservation_amount,
        0,
        NodeMsg
    ),
    non_negative_int(Value, 0).

reservation_ttl_ms(NodeMsg) ->
    positive_int_config(
        <<"ao-payment-reservation-ttl-ms">>,
        ao_payment_reservation_ttl_ms,
        ?DEFAULT_RESERVATION_TTL_MS,
        NodeMsg
    ).

%% @doc Verify that an AO message produced matching token debit/credit notices.
verify(_Base, Req, NodeMsg) ->
    MessageID =
        case request_value(<<"message-id">>, Req, undefined) of
            undefined -> request_value(<<"id">>, Req, undefined);
            ID -> ID
        end,
    Slot = request_value(<<"slot">>, Req, undefined),
    Sender = request_value(<<"sender">>, Req, undefined),
    Quantity0 = request_value(<<"quantity">>, Req, undefined),
    RequestedRecipient = request_value(<<"recipient">>, Req, undefined),
    case configured_payment_scope(Req, NodeMsg) of
        {error, ScopeError} ->
            {error, ScopeError};
        {ok, Token, Ledger, DepositAddress, LedgerPath} ->
            case {
                lists:any(fun missing_value/1, [MessageID, Slot, Sender, Quantity0]),
                parse_positive_quantity(Quantity0),
                normalize_target(Sender) =:= normalize_target(DepositAddress)
            } of
                {true, _, _} ->
                    {error, #{
                        <<"status">> => 400,
                        <<"body">> => <<"Missing message-id, slot, sender, or quantity.">>
                    }};
                {false, {error, _}, _} ->
                    {error, #{
                        <<"status">> => 400,
                        <<"body">> => <<"AO payment quantity must be positive.">>
                    }};
                {false, {ok, _Quantity}, true} ->
                    {error, #{
                        <<"status">> => 400,
                        <<"body">> => <<"AO payment sender cannot be the deposit address.">>
                    }};
                {false, {ok, Quantity}, false} ->
                    verify_payment(
                        Token,
                        Ledger,
                        DepositAddress,
                        LedgerPath,
                        MessageID,
                        Slot,
                        Sender,
                        hb_util:bin(Quantity),
                        RequestedRecipient,
                        NodeMsg
                    )
            end
    end.

verify_payment(
    Token,
    Ledger,
    DepositAddress,
    LedgerPath,
    MessageID,
    Slot,
    Sender,
    Quantity,
    RequestedRecipient,
    NodeMsg
) ->
    case fetch_schedule(Token, Slot, NodeMsg) of
        {ok, Result} ->
            Expected = #{
                <<"token">> => Token,
                <<"ledger">> => Ledger,
                <<"deposit-address">> => DepositAddress,
                <<"message-id">> => MessageID,
                <<"slot">> => hb_util:bin(Slot),
                <<"sender">> => Sender,
                <<"quantity">> => Quantity,
                <<"ledger-path">> => LedgerPath,
                <<"requested-recipient">> => RequestedRecipient
            },
            case verify_schedule(Result, Expected, NodeMsg) of
                ok ->
                    case fetch_result(Token, Slot, NodeMsg) of
                        {ok, ComputeResult} ->
                            verify_result(ComputeResult, Expected, NodeMsg);
                        {error, Reason} ->
                            fetch_error(Reason)
                    end;
                Error ->
                    Error
            end;
        {error, Reason} ->
            fetch_error(Reason)
    end.

configured_payment_scope(Req, NodeMsg) ->
    Token = configured_value(
        <<"ao-payment-token">>,
        ao_payment_token,
        ?DEFAULT_AO_TOKEN,
        NodeMsg
    ),
    DepositAddress =
        case configured_value(
            <<"ao-payment-deposit-address">>,
            ao_payment_deposit_address,
            undefined,
            NodeMsg
        ) of
            undefined -> configured_value(<<"operator">>, operator, undefined, NodeMsg);
            Address -> Address
        end,
    LedgerPath = configured_ledger_path(NodeMsg),
    case configured_payment_ledger(LedgerPath, NodeMsg) of
        {error, LedgerReason} ->
            {error, #{
                <<"status">> => 500,
                <<"body">> => <<"AO payment ledger identity is not available.">>,
                <<"reason">> => format_reason(LedgerReason)
            }};
        {ok, Ledger} ->
            configured_payment_scope(
                Req,
                Token,
                Ledger,
                DepositAddress,
                LedgerPath
            )
    end.

configured_payment_scope(Req, Token, Ledger, DepositAddress, LedgerPath) ->
    case lists:any(fun missing_value/1, [Token, Ledger, DepositAddress, LedgerPath]) of
        true ->
            {error, #{
                <<"status">> => 500,
                <<"body">> => <<"AO payment scope is not fully configured.">>
            }};
        false ->
            Scope = [
                {<<"token">>, Token},
                {<<"ledger">>, Ledger},
                {<<"deposit-address">>, DepositAddress},
                {<<"ledger-path">>, LedgerPath}
            ],
            case lists:dropwhile(
                fun({Key, Expected}) -> request_scope_matches(Key, Expected, Req) end,
                Scope
            ) of
                [] ->
                    {ok,
                        normalize_target(Token),
                        normalize_target(Ledger),
                        normalize_target(DepositAddress),
                        normalize_route(LedgerPath)};
                [{Key, _Expected} | _] ->
                    {error, #{
                        <<"status">> => 400,
                        <<"body">> => <<"AO payment request conflicts with configured scope.">>,
                        <<"field">> => Key
                    }}
            end
    end.

configured_payment_ledger(LedgerPath, NodeMsg) ->
    case configured_value(
        <<"ao-payment-ledger">>,
        ao_payment_ledger,
        undefined,
        NodeMsg
    ) of
        undefined -> derive_ledger_id(LedgerPath, NodeMsg);
        Ledger -> {ok, normalize_target(Ledger)}
    end.

derive_ledger_id(undefined, _NodeMsg) ->
    {error, missing_ledger_path};
derive_ledger_id(LedgerPath, NodeMsg) ->
    try
        <<"/", NamedPath/binary>> = normalize_route(LedgerPath),
        [LedgerName, _Device] = binary:split(NamedPath, <<"~">>),
        Opts = ledger_resolve_opts(NodeMsg),
        case hb_ao:resolve(
            #{ <<"device">> => <<"node-process@1.0">> },
            LedgerName,
            Opts
        ) of
            {ok, LedgerMsg} ->
                {ok, hb_util:human_id(hb_message:id(LedgerMsg, signed, Opts))};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        Class:CatchReason -> {error, {Class, CatchReason}}
    end.

request_scope_matches(Key, Expected, Req) ->
    case direct_get(Key, Req) of
        undefined -> true;
        Supplied when Key =:= <<"ledger-path">> ->
            normalize_route(Supplied) =:= normalize_route(Expected);
        Supplied ->
            normalize_target(Supplied) =:= normalize_target(Expected)
    end.

missing_value(undefined) -> true;
missing_value(<<"undefined">>) -> true;
missing_value(<<>>) -> true;
missing_value(_) -> false.

fetch_schedule(Token, Slot, NodeMsg) ->
    BaseURL = mainnet_url(NodeMsg),
    SlotBin = hb_util:bin(Slot),
    URL =
        <<BaseURL/binary, "/", Token/binary, "~process@1.0/schedule?from=",
            SlotBin/binary, "&to=", SlotBin/binary, "&accept=application/aos-2">>,
    fetch_json(URL).

fetch_result(Token, Slot, NodeMsg) ->
    BaseURL = mainnet_url(NodeMsg),
    SlotBin = hb_util:bin(Slot),
    URL =
        <<BaseURL/binary, "/", Token/binary, "~process@1.0/compute&slot=",
            SlotBin/binary,
            "/results?require-codec=application/json&accept-bundle=true">>,
    fetch_json(URL).

mainnet_url(NodeMsg) ->
    URL0 = hb_opts:get(ao_payment_mainnet_url, ?DEFAULT_MAINNET_URL, NodeMsg),
    case binary:last(URL0) of
            $/ -> binary:part(URL0, 0, byte_size(URL0) - 1);
            _ -> URL0
    end.

fetch_json(URL) ->
    case httpc:request(
        get,
        {binary_to_list(URL), [{"accept", "application/json"}]},
        http_options(),
        [{body_format, binary}]
    ) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            {ok, hb_json:decode(Body)};
        {ok, {{_, Status, _}, _Headers, Body}} ->
            {error, {http_status, Status, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

fetch_error(Reason) ->
    {error, #{
        <<"status">> => 502,
        <<"body">> => <<"Unable to fetch AO payment data from mainnet endpoint.">>,
        <<"reason">> => format_reason(Reason)
    }}.

format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

verify_schedule(Schedule, Expected, NodeMsg) ->
    Edges = hb_maps:get(<<"edges">>, Schedule, [], NodeMsg),
    MessageID = hb_maps:get(<<"message-id">>, Expected, undefined, NodeMsg),
    DepositAddress = hb_maps:get(<<"deposit-address">>, Expected, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
    Slot = hb_maps:get(<<"slot">>, Expected, undefined, NodeMsg),
    Found =
        lists:any(
            fun(Edge) ->
                Node = hb_maps:get(<<"node">>, Edge, #{}, NodeMsg),
                Message = hb_maps:get(<<"message">>, Node, #{}, NodeMsg),
                Assignment = hb_maps:get(<<"assignment">>, Node, #{}, NodeMsg),
                MessageTags = hb_maps:get(<<"Tags">>, Message, [], NodeMsg),
                AssignmentTags = hb_maps:get(<<"Tags">>, Assignment, [], NodeMsg),
                hb_maps:get(<<"Id">>, Message, undefined, NodeMsg) =:= MessageID
                    andalso tag_value(MessageTags, <<"Action">>, NodeMsg) =:= <<"Transfer">>
                    andalso tag_value(MessageTags, <<"Recipient">>, NodeMsg) =:= DepositAddress
                    andalso hb_util:bin(tag_value(MessageTags, <<"Quantity">>, NodeMsg)) =:= Quantity
                    andalso hb_util:bin(tag_value(AssignmentTags, <<"Nonce">>, NodeMsg)) =:= Slot
            end,
            Edges
        ),
    case Found of
        true -> ok;
        false ->
            {error, #{
                <<"status">> => 402,
                <<"body">> => <<"AO schedule did not contain the expected Transfer assignment.">>
            }}
    end.

verify_result(Result, Expected, NodeMsg) ->
    Raw = hb_maps:get(<<"raw">>, Result, Result, NodeMsg),
    Messages = hb_maps:get(<<"Messages">>, Raw, [], NodeMsg),
    DepositAddress = hb_maps:get(<<"deposit-address">>, Expected, undefined, NodeMsg),
    Sender = hb_maps:get(<<"sender">>, Expected, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
    Debit = find_notice(
        <<"Debit-Notice">>,
        Sender,
        #{<<"Recipient">> => DepositAddress, <<"Quantity">> => Quantity},
        Messages,
        NodeMsg
    ),
    Credit = find_notice(
        <<"Credit-Notice">>,
        DepositAddress,
        #{<<"Sender">> => Sender, <<"Quantity">> => Quantity},
        Messages,
        NodeMsg
    ),
    case {Debit, Credit} of
        {{value, _DebitMsg}, {value, CreditMsg}} ->
            credit_to_payment(CreditMsg, Expected, NodeMsg);
        _ ->
            {error, #{
                <<"status">> => 402,
                <<"body">> => <<"AO result did not contain the expected Debit-Notice and Credit-Notice.">>
            }}
    end.

find_notice(Action, Target, RequiredTags, Messages, NodeMsg) ->
    lists:search(
        fun(Msg) ->
            Tags = hb_maps:get(<<"Tags">>, Msg, [], NodeMsg),
            hb_maps:get(<<"Target">>, Msg, undefined, NodeMsg) =:= Target
                andalso tag_value(Tags, <<"Action">>, NodeMsg) =:= Action
                andalso maps:fold(
                    fun(Name, Value, Acc) ->
                        Acc andalso hb_util:bin(tag_value(Tags, Name, NodeMsg)) =:= Value
                    end,
                    true,
                    RequiredTags
                )
        end,
        Messages
    ).

credit_to_payment(CreditMsg, Expected, NodeMsg) ->
    Tags = hb_maps:get(<<"Tags">>, CreditMsg, [], NodeMsg),
    Sender = hb_maps:get(<<"sender">>, Expected, undefined, NodeMsg),
    RequestedRecipient = hb_maps:get(<<"requested-recipient">>, Expected, undefined, NodeMsg),
    Recipient =
        case tag_value(Tags, <<"X-HB-Recipient">>, NodeMsg) of
            undefined -> Sender;
            ForwardedRecipient -> ForwardedRecipient
        end,
    case RequestedRecipient =:= undefined orelse RequestedRecipient =:= Recipient of
        true ->
            {ok, #{
                <<"token">> => hb_maps:get(<<"token">>, Expected, undefined, NodeMsg),
                <<"message-id">> => hb_maps:get(<<"message-id">>, Expected, undefined, NodeMsg),
                <<"ledger">> => hb_maps:get(<<"ledger">>, Expected, undefined, NodeMsg),
                <<"ledger-path">> => hb_maps:get(<<"ledger-path">>, Expected, undefined, NodeMsg),
                <<"sender">> => Sender,
                <<"recipient">> => Recipient,
                <<"quantity">> => hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
                <<"notice-reference">> => tag_value(Tags, <<"Reference">>, NodeMsg)
            }};
        false ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"Requested recipient does not match AO Credit-Notice.">>,
                <<"recipient">> => Recipient
            }}
    end.

prepare_payment_import(Payment, NodeMsg) ->
    case read_ledger_balance(Payment, NodeMsg) of
        {ok, BeforeBalance} ->
            Quantity =
                hb_util:int(
                    hb_maps:get(<<"quantity">>, Payment, undefined, NodeMsg)
                ),
            {ok, Payment#{
                <<"status">> => <<"prepared">>,
                <<"balance-before">> => BeforeBalance,
                <<"expected-balance">> => BeforeBalance + Quantity,
                <<"credit-notice">> => prepare_credit_notice(Payment, NodeMsg)
            }};
        Error ->
            Error
    end.

schedule_new_import(PaymentKey, PendingPayment, NodeMsg) ->
    case schedule_credit_notice(PendingPayment, NodeMsg) of
        {ok, _ScheduleResult} ->
            ScheduledPayment = PendingPayment#{ <<"status">> => <<"scheduled">> },
            case store_import(PaymentKey, ScheduledPayment, NodeMsg) of
                ok -> settle_import(PaymentKey, ScheduledPayment, NodeMsg);
                {error, Reason} ->
                    payment_import_error(
                        500,
                        <<"AO payment was scheduled but its durable state could not be updated.">>,
                        Reason
                    )
            end;
        {error, Reason} ->
            payment_import_error(
                502,
                <<"Unable to schedule AO payment credit into local ledger.">>,
                Reason
            )
    end.

settle_import(PaymentKey, PendingPayment, NodeMsg) ->
    case await_imported_payment(PendingPayment, NodeMsg) of
        {ok, ImportedPayment0} ->
            ImportedPayment = maps:remove(
                <<"credit-notice">>,
                ImportedPayment0#{ <<"status">> => <<"imported">> }
            ),
            case store_import(PaymentKey, ImportedPayment, NodeMsg) of
                ok -> {ok, ImportedPayment};
                {error, Reason} ->
                    payment_import_error(
                        500,
                        <<"AO payment settled but its durable import record could not be updated.">>,
                        Reason
                    )
            end;
        Error ->
            Error
    end.

load_import(PaymentKey, NodeMsg) ->
    case persistent_state_read(import_path(PaymentKey), undefined, NodeMsg) of
        {ok, undefined} ->
            load_legacy_import(PaymentKey, NodeMsg);
        {ok, Payment} when is_map(Payment) ->
            {ok, Payment};
        {ok, _Invalid} ->
            {error, invalid_import_state};
        Error ->
            Error
    end.

load_legacy_import(PaymentKey, NodeMsg) ->
    Imports = hb_opts:get(ao_payment_imports, #{}, NodeMsg),
    case maps:find(PaymentKey, Imports) of
        {ok, Payment} when is_map(Payment) ->
            case store_import(PaymentKey, Payment, NodeMsg) of
                ok -> {ok, Payment};
                Error -> Error
            end;
        _ ->
            not_found
    end.

store_import(PaymentKey, Payment, NodeMsg) ->
    persistent_state_write(import_path(PaymentKey), Payment, NodeMsg).

import_path(PaymentKey) ->
    state_path(<<"imports">>, PaymentKey).

with_payment_lock(PaymentKey, Fun) ->
    Lock = {{?MODULE, node(), import, PaymentKey}, self()},
    case global:trans(Lock, Fun) of
        aborted ->
            payment_import_error(
                503,
                <<"Unable to acquire AO payment import lock.">>,
                import_lock_aborted
            );
        Result ->
            Result
    end.

submit_and_store_withdrawal(Key, Withdrawal, NodeMsg) ->
    submit_and_store_withdrawal(
        Key,
        Withdrawal,
        NodeMsg,
        fun submit_prepared_withdrawal/2
    ).

submit_and_store_withdrawal(Key, Withdrawal, NodeMsg, SubmitFun) ->
    case load_withdrawal(Key, NodeMsg) of
        {ok, Existing} ->
            existing_withdrawal_response(Existing, Withdrawal, NodeMsg);
        not_found ->
            Prepared = prepare_withdrawal(Withdrawal, NodeMsg),
            case store_withdrawal(Key, Prepared, NodeMsg) of
                ok ->
                    complete_withdrawal_submission(
                        Key,
                        Prepared,
                        NodeMsg,
                        SubmitFun
                    );
                {error, Reason} ->
                    payment_import_error(
                        500,
                        <<"Unable to persist AO withdrawal intent before submission.">>,
                        Reason
                    )
            end;
        {error, Reason} ->
            payment_import_error(
                500,
                <<"Unable to read AO withdrawal state.">>,
                Reason
            )
    end.

complete_withdrawal_submission(Key, Prepared, NodeMsg, SubmitFun) ->
    case SubmitFun(Prepared, NodeMsg) of
        {ok, SubmitResult} ->
            Submitted = Prepared#{
                <<"status">> => <<"submitted">>,
                <<"submitted-at">> => erlang:system_time(millisecond),
                <<"submit-response">> => SubmitResult
            },
            case store_withdrawal(Key, Submitted, NodeMsg) of
                ok ->
                    {ok, withdrawal_response(Submitted)};
                {error, Reason} ->
                    payment_import_error(
                        503,
                        <<"AO withdrawal was submitted but its durable state could not be updated; automatic resubmission is disabled.">>,
                        Reason
                    )
            end;
        {error, Reason} ->
            Uncertain = Prepared#{
                <<"status">> => <<"uncertain">>,
                <<"submit-error">> => format_reason(Reason)
            },
            _ = store_withdrawal(Key, Uncertain, NodeMsg),
            uncertain_withdrawal_error(Uncertain, Reason)
    end.

existing_withdrawal_response(Existing, Withdrawal, NodeMsg) ->
    case withdrawal_matches(Existing, Withdrawal, NodeMsg) of
        false ->
            withdraw_error(
                409,
                <<"AO withdrawal ID conflicts with an existing withdrawal intent.">>
            );
        true ->
            case payment_status(Existing) of
                <<"submitted">> ->
                    {ok,
                        (withdrawal_response(Existing))#{
                            <<"status">> => <<"already-submitted">>
                        }};
                <<"already-submitted">> ->
                    {ok, withdrawal_response(Existing)};
                _ ->
                    {error, #{
                        <<"status">> => 503,
                        <<"body">> =>
                            <<"AO withdrawal outcome is uncertain; automatic resubmission is disabled.">>,
                        <<"message-id">> =>
                            hb_maps:get(<<"message-id">>, Existing, undefined, NodeMsg)
                    }}
            end
    end.

withdrawal_matches(Existing, Withdrawal, NodeMsg) ->
    try
        normalize_target(hb_maps:get(<<"token">>, Existing, undefined, NodeMsg)) =:=
            normalize_target(hb_maps:get(<<"token">>, Withdrawal, undefined, NodeMsg))
            andalso normalize_target(
                hb_maps:get(<<"recipient">>, Existing, undefined, NodeMsg)
            ) =:= normalize_target(
                hb_maps:get(<<"recipient">>, Withdrawal, undefined, NodeMsg)
            )
            andalso hb_util:int(
                hb_maps:get(<<"quantity">>, Existing, undefined, NodeMsg)
            ) =:= hb_util:int(
                hb_maps:get(<<"quantity">>, Withdrawal, undefined, NodeMsg)
            )
    catch
        _:_ -> false
    end.

withdrawal_response(Withdrawal) ->
    maps:without([<<"signed-item">>], Withdrawal).

load_withdrawal(Key, NodeMsg) ->
    case persistent_state_read(withdrawal_path(Key), undefined, NodeMsg) of
        {ok, undefined} ->
            load_legacy_withdrawal(Key, NodeMsg);
        {ok, Withdrawal} when is_map(Withdrawal) ->
            {ok, Withdrawal};
        {ok, _Invalid} ->
            {error, invalid_withdrawal_state};
        Error ->
            Error
    end.

load_legacy_withdrawal(Key, NodeMsg) ->
    Withdrawals = hb_opts:get(ao_payment_withdrawals, #{}, NodeMsg),
    case maps:find(Key, Withdrawals) of
        {ok, Withdrawal} when is_map(Withdrawal) ->
            case store_withdrawal(Key, Withdrawal, NodeMsg) of
                ok -> {ok, Withdrawal};
                Error -> Error
            end;
        _ ->
            not_found
    end.

store_withdrawal(Key, Withdrawal, NodeMsg) ->
    persistent_state_write(withdrawal_path(Key), Withdrawal, NodeMsg).

withdrawal_path(Key) ->
    state_path(<<"withdrawals">>, Key).

with_withdrawal_lock(Key, Fun) ->
    Lock = {{?MODULE, node(), withdrawal, Key}, self()},
    case global:trans(Lock, Fun) of
        aborted ->
            payment_import_error(
                503,
                <<"Unable to acquire AO withdrawal lock.">>,
                withdrawal_lock_aborted
            );
        Result ->
            Result
    end.

auto_withdraw_enabled(_Base, NodeMsg) ->
    enabled(
        configured_value(
            <<"ao-payment-auto-withdraw">>,
            ao_payment_auto_withdraw,
            false,
            NodeMsg
        )
    ).

prepare_credit_notice(Payment, NodeMsg) ->
    Opts = wallet_opts(NodeMsg),
    Ledger = hb_maps:get(<<"ledger">>, Payment, undefined, NodeMsg),
    hb_message:commit(
        #{
            <<"target">> => Ledger,
            <<"type">> => <<"Message">>,
            <<"action">> => <<"Credit-Notice">>,
            <<"from-process">> => hb_maps:get(<<"token">>, Payment, undefined, NodeMsg),
            <<"recipient">> => hb_maps:get(<<"recipient">>, Payment, undefined, NodeMsg),
            <<"quantity">> => hb_util:int(hb_maps:get(<<"quantity">>, Payment, undefined, NodeMsg)),
            <<"sender">> => hb_maps:get(<<"sender">>, Payment, undefined, NodeMsg),
            <<"ao-payment-id">> => hb_maps:get(<<"message-id">>, Payment, undefined, NodeMsg)
        },
        Opts
    ).

schedule_credit_notice(Payment, NodeMsg) ->
    Opts = wallet_opts(NodeMsg),
    LedgerRoute = ledger_route(Payment, NodeMsg),
    CreditNotice = hb_maps:get(<<"credit-notice">>, Payment, undefined, NodeMsg),
    case CreditNotice of
        undefined ->
            {error, missing_persisted_credit_notice};
        _ ->
            schedule_credit_notice_at(LedgerRoute, CreditNotice, Opts, NodeMsg)
    end.

schedule_credit_notice_at(LedgerRoute, CreditNotice, Opts, NodeMsg) ->
    Node = local_node(NodeMsg),
    try
        hb_http:post(
            Node,
            <<LedgerRoute/binary, "/schedule">>,
            CreditNotice,
            Opts
        )
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

await_imported_payment(Payment, NodeMsg) ->
    BeforeBalance =
        hb_maps:get(<<"balance-before">>, Payment, 0, NodeMsg),
    ExpectedBalance =
        hb_maps:get(
            <<"expected-balance">>,
            Payment,
            BeforeBalance +
                hb_util:int(hb_maps:get(<<"quantity">>, Payment, undefined, NodeMsg)),
            NodeMsg
        ),
    Deadline =
        erlang:monotonic_time(millisecond) + settlement_timeout_ms(NodeMsg),
    wait_for_ledger_credit(
        Payment,
        BeforeBalance,
        ExpectedBalance,
        Deadline,
        undefined,
        NodeMsg
    ).

wait_for_ledger_credit(Payment, BeforeBalance, ExpectedBalance, Deadline, _LastSeen, NodeMsg) ->
    case read_ledger_balance(Payment, NodeMsg) of
        {ok, Balance} when Balance >= ExpectedBalance ->
            {ok, Payment#{
                <<"status">> => <<"imported">>,
                <<"balance-before">> => BeforeBalance,
                <<"balance-after">> => Balance,
                <<"expected-balance">> => ExpectedBalance
            }};
        {ok, Balance} ->
            wait_or_timeout(
                Payment,
                BeforeBalance,
                ExpectedBalance,
                Deadline,
                {balance, Balance},
                NodeMsg
            );
        {error, Error} ->
            wait_or_timeout(
                Payment,
                BeforeBalance,
                ExpectedBalance,
                Deadline,
                {error, Error},
                NodeMsg
            )
    end.

wait_or_timeout(Payment, BeforeBalance, ExpectedBalance, Deadline, LastSeen, NodeMsg) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            settlement_timeout_error(
                Payment,
                BeforeBalance,
                ExpectedBalance,
                LastSeen,
                NodeMsg
            );
        false ->
            timer:sleep(erlang:min(settlement_poll_ms(NodeMsg), Deadline - Now)),
            wait_for_ledger_credit(
                Payment,
                BeforeBalance,
                ExpectedBalance,
                Deadline,
                LastSeen,
                NodeMsg
            )
    end.

read_ledger_balance(Payment, NodeMsg) ->
    LedgerRoute = ledger_route(Payment, NodeMsg),
    Recipient = hb_maps:get(<<"recipient">>, Payment, undefined, NodeMsg),
    case Recipient of
        undefined ->
            payment_import_error(
                400,
                <<"AO payment did not resolve a local ledger recipient.">>,
                missing_recipient
            );
        _ ->
            read_ledger_balance_at(LedgerRoute, Recipient, NodeMsg)
    end.

read_ledger_balance_at(LedgerPath, Recipient, ResolveOpts) ->
    LedgerRoute = normalize_route(LedgerPath),
    BalancePath = <<LedgerRoute/binary, "/now/balance/", Recipient/binary>>,
    case hb_ao:resolve(#{ <<"path">> => BalancePath }, ResolveOpts) of
        {ok, Balance} ->
            normalize_balance(Balance);
        {error, Reason} when Reason =:= not_found ->
            {ok, 0};
        {error, Reason} ->
            payment_import_error(
                503,
                <<"Unable to read local payment ledger balance.">>,
                Reason
            )
    end.

read_p4_ledger_balance_at(LedgerPath, Recipient, ResolveOpts) ->
    read_p4_ledger_balance_at(
        LedgerPath,
        Recipient,
        ResolveOpts,
        ?LEDGER_READ_ATTEMPTS
    ).

read_p4_ledger_balance_at(LedgerPath, Recipient, ResolveOpts, Attempts) ->
    LedgerRoute = normalize_route(LedgerPath),
    BalancePath = <<LedgerRoute/binary, "/now/balance">>,
    case hb_ao:resolve(#{ <<"path">> => BalancePath }, ResolveOpts) of
        {ok, Balances} when is_map(Balances) ->
            normalize_balance(hb_ao:get(Recipient, Balances, 0, ResolveOpts));
        {ok, Balance} ->
            normalize_balance(Balance);
        {error, Reason} when Reason =:= not_found ->
            {ok, 0};
        {error, _Reason} when Attempts > 1 ->
            timer:sleep(?LEDGER_READ_RETRY_MS),
            read_p4_ledger_balance_at(
                LedgerPath,
                Recipient,
                ResolveOpts,
                Attempts - 1
            );
        {error, Reason} ->
            payment_import_error(
                503,
                <<"Unable to read local payment ledger balance.">>,
                Reason
            )
    end.

ledger_resolve_opts(NodeMsg) ->
    lists:foldl(
        fun({OptKey, MsgKey}, Acc) ->
            case hb_opts:get(OptKey, undefined) of
                undefined -> Acc;
                Value -> Acc#{ OptKey => Value, MsgKey => Value }
            end
        end,
        NodeMsg,
        [
            {preloaded_store, <<"preloaded-store">>},
            {preloaded_devices_index, <<"preloaded-devices-index">>}
        ]
    ).

balance_target(Req, NodeMsg) ->
    case normalize_target(direct_get(<<"target">>, Req)) of
        undefined ->
            case direct_get(<<"request">>, Req) of
                undefined -> signer_target(Req, NodeMsg);
                NestedReq ->
                    case target_from_message(NestedReq, NodeMsg) of
                        undefined -> signer_target(Req, NodeMsg);
                        Target -> Target
                    end
            end;
        Target ->
            Target
    end.

target_from_message(Msg, NodeMsg) ->
    case normalize_target(direct_get(<<"target">>, Msg)) of
        undefined -> signer_target(Msg, NodeMsg);
        Target ->
            Target
    end.

signer_target(Msg, NodeMsg) ->
    case message_signers(Msg, NodeMsg) of
        [] -> undefined;
        [Signer | _] -> normalize_target(Signer)
    end.

message_signers(Msg, _NodeMsg) when is_map(Msg), map_size(Msg) =:= 0 ->
    [];
message_signers(Msg, NodeMsg) ->
    try hb_message:signers(Msg, NodeMsg)
    catch
        _:_ -> []
    end.

normalize_target(Target) when is_binary(Target) ->
    try hb_util:human_id(hb_util:committer_address(Target))
    catch _:_ -> Target
    end;
normalize_target(_) ->
    undefined.

enabled(true) -> true;
enabled(<<"true">>) -> true;
enabled(1) -> true;
enabled(<<"1">>) -> true;
enabled(_) -> false.

normalize_balance(Balance) ->
    try {ok, hb_util:int(Balance)}
    catch
        _:_ ->
            payment_import_error(
                503,
                <<"Local payment ledger returned a non-integer balance.">>,
                Balance
            )
    end.

payment_import_error(Status, Body, Reason) ->
    {error, #{
        <<"status">> => Status,
        <<"body">> => Body,
        <<"reason">> => format_reason(Reason)
    }}.

settlement_timeout_error(Payment, BeforeBalance, ExpectedBalance, LastSeen, NodeMsg) ->
    Timeout = settlement_timeout_ms(NodeMsg),
    Error = #{
        <<"status">> => 503,
        <<"body">> =>
            <<"AO payment import did not settle before timeout; automatic scheduling retry is disabled.">>,
        <<"balance-before">> => BeforeBalance,
        <<"expected-balance">> => ExpectedBalance,
        <<"timeout-ms">> => Timeout,
        <<"recipient">> => hb_maps:get(<<"recipient">>, Payment, undefined, NodeMsg),
        <<"message-id">> => hb_maps:get(<<"message-id">>, Payment, undefined, NodeMsg)
    },
    {error, annotate_last_seen(Error, LastSeen)}.

annotate_last_seen(Error, undefined) ->
    Error;
annotate_last_seen(Error, {balance, Balance}) ->
    Error#{ <<"last-balance">> => Balance };
annotate_last_seen(Error, {error, {error, LastError}}) ->
    Error#{
        <<"last-error">> =>
            hb_maps:get(<<"body">>, LastError, format_reason(LastError), #{})
    };
annotate_last_seen(Error, {error, LastError}) ->
    Error#{ <<"last-error">> => format_reason(LastError) }.

validate_withdrawal(Base, Req, NodeMsg) ->
    case authorize_withdrawal(Base, Req, NodeMsg) of
        ok -> validate_withdrawal_fields(Base, Req, NodeMsg);
        Error -> Error
    end.

authorize_withdrawal(Base, Req, NodeMsg) ->
    ExpectedSecret = withdraw_secret(NodeMsg),
    SuppliedSecret = direct_get(<<"withdraw-secret">>, Req),
    case ExpectedSecret of
        SuppliedSecret when ExpectedSecret =/= undefined ->
            ok;
        _ ->
            authorize_withdrawal_signer(Base, Req, NodeMsg)
    end.

authorize_withdrawal_signer(Base, Req, NodeMsg) ->
    Allowed = withdraw_authorized_signers(Base, NodeMsg),
    Signers = verified_message_signers(Req, NodeMsg),
    case [Signer || Signer <- Signers, lists:member(Signer, Allowed)] of
        [_ | _] ->
            ok;
        [] ->
            withdraw_error(403, <<"AO payment withdrawal request is not signed by the operator.">>)
    end.

withdraw_authorized_signers(_Base, NodeMsg) ->
    lists:usort(
        [
            Signer
         || Signer <- [normalize_target(
                configured_value(<<"operator">>, operator, undefined, NodeMsg)
            )],
            Signer =/= undefined
        ]
    ).

configured_charge_recipients(NodeMsg) ->
    lists:usort(
        [
            Recipient
         || Recipient <- [
                normalize_target(
                    configured_value(
                        <<"p4-recipient">>,
                        p4_recipient,
                        undefined,
                        NodeMsg
                    )
                ),
                normalize_target(
                    configured_value(
                        <<"operator">>,
                        operator,
                        undefined,
                        NodeMsg
                    )
                )
            ],
            Recipient =/= undefined
        ]
    ).

verified_message_signers(Msg, NodeMsg) ->
    case has_commitments(Msg) of
        true -> verified_message_signers_1(Msg, NodeMsg);
        false -> []
    end.

verified_message_signers_1(Msg, NodeMsg) ->
    try hb_message:verify(Msg, signers, NodeMsg) of
        true ->
            [
                Signer
             || Signer0 <- message_signers(Msg, NodeMsg),
                Signer <- [normalize_target(Signer0)],
                Signer =/= undefined
            ];
        _ -> []
    catch
        _:_ -> []
    end.

has_commitments(Msg) when is_map(Msg) ->
    case direct_get(<<"commitments">>, Msg) of
        Commitments when is_map(Commitments) -> map_size(Commitments) > 0;
        Commitments when is_list(Commitments) -> Commitments =/= [];
        _ -> false
    end;
has_commitments(_) ->
    false.

validate_withdrawal_fields(Base, Req, NodeMsg) ->
    TokenDefault =
        configured_value(
            <<"ao-payment-token">>,
            ao_payment_token,
            ?DEFAULT_AO_TOKEN,
            NodeMsg
        ),
    Recipient = direct_get(<<"recipient">>, Req),
    Quantity0 = direct_get(<<"quantity">>, Req),
    WithdrawID = direct_get(<<"withdraw-id">>, Req),
    case {
        request_scope_matches(<<"token">>, TokenDefault, Req),
        Recipient,
        parse_positive_quantity(Quantity0)
    } of
        {false, _, _} ->
            withdraw_error(400, <<"Withdrawal token conflicts with node configuration.">>);
        {true, undefined, _} ->
            withdraw_error(400, <<"Missing withdrawal recipient.">>);
        {true, _, {error, _}} ->
            withdraw_error(400, <<"Invalid withdrawal quantity.">>);
        {true, _, {ok, Quantity}} ->
            AllowedRecipient = allowed_withdraw_recipient(Base, NodeMsg),
            case AllowedRecipient of
                undefined ->
                    payment_import_error(
                        500,
                        <<"AO withdrawal recipient is not configured.">>,
                        missing_withdraw_recipient
                    );
                _ ->
                    case hb_util:human_id(AllowedRecipient) =:=
                        hb_util:human_id(Recipient)
                    of
                        true ->
                            {ok, #{
                                <<"token">> => hb_util:human_id(TokenDefault),
                                <<"recipient">> => hb_util:human_id(Recipient),
                                <<"quantity">> => Quantity,
                                <<"withdraw-id">> => WithdrawID,
                                <<"submit-url">> => submit_url(Base, NodeMsg)
                            }};
                        false ->
                            withdraw_error(
                                403,
                                <<"Withdrawal recipient does not match configured beneficiary.">>
                            )
                    end
            end
    end.

withdraw_secret(NodeMsg) ->
    hb_private:get(
        <<"ao-payment-withdraw-secret">>,
        NodeMsg,
        hb_private:get(<<"withdraw-secret">>, NodeMsg, undefined, NodeMsg),
        NodeMsg
    ).

allowed_withdraw_recipient(_Base, NodeMsg) ->
    configured_value(
        <<"ao-payment-withdraw-recipient">>,
        ao_payment_withdraw_recipient,
        configured_value(
            <<"p4-recipient">>,
            p4_recipient,
            configured_value(
                <<"ao-payment-deposit-address">>,
                ao_payment_deposit_address,
                undefined,
                NodeMsg
            ),
            NodeMsg
        ),
        NodeMsg
    ).

parse_positive_quantity(undefined) ->
    {error, missing};
parse_positive_quantity(Quantity0) ->
    try hb_util:int(Quantity0) of
        Quantity when Quantity > 0 -> {ok, Quantity};
        _ -> {error, invalid}
    catch
        _:_ -> {error, invalid}
    end.

prepare_withdrawal(Withdrawal, NodeMsg) ->
    Opts = wallet_opts(NodeMsg),
    Token = hb_maps:get(<<"token">>, Withdrawal, ?DEFAULT_AO_TOKEN, NodeMsg),
    Recipient = hb_maps:get(<<"recipient">>, Withdrawal, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Withdrawal, undefined, NodeMsg),
    Item = ar_bundles:sign_item(
        #tx{
            target = hb_util:decode(Token),
            data = <<"1984">>,
            tags = [
                {<<"Data-Protocol">>, <<"ao">>},
                {<<"Variant">>, <<"ao.TN.1">>},
                {<<"Type">>, <<"Message">>},
                {<<"Action">>, <<"Transfer">>},
                {<<"Recipient">>, Recipient},
                {<<"Quantity">>, hb_util:bin(Quantity)},
                {<<"Content-Type">>, <<"text/plain">>},
                {<<"SDK">>, <<"hyperbeam-lapee">>}
            ]
        },
        maps:get(priv_wallet, Opts)
    ),
    MessageID = hb_util:human_id(Item#tx.id),
    Withdrawal#{
        <<"status">> => <<"prepared">>,
        <<"message-id">> => MessageID,
        <<"signed-item">> => Item,
        <<"prepared-at">> => erlang:system_time(millisecond)
    }.

submit_prepared_withdrawal(Prepared, NodeMsg) ->
    Item = hb_maps:get(<<"signed-item">>, Prepared, undefined, NodeMsg),
    case post_legacy_mu(
        hb_maps:get(<<"submit-url">>, Prepared, ?DEFAULT_SUBMIT_URL, NodeMsg),
        Item
    ) of
        {ok, SubmitResult} -> {ok, SubmitResult};
        Error -> Error
    end.

uncertain_withdrawal_error(Prepared, Reason) ->
    {error, #{
        <<"status">> => 503,
        <<"body">> =>
            <<"AO withdrawal submission outcome is uncertain; automatic resubmission is disabled.">>,
        <<"message-id">> => hb_maps:get(<<"message-id">>, Prepared, undefined, #{}),
        <<"reason">> => format_reason(Reason)
    }}.

post_legacy_mu(SubmitURL0, Item) ->
    SubmitURL = normalize_url(SubmitURL0),
    Body = ar_bundles:serialize(Item),
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    Request = {
        binary_to_list(SubmitURL),
        [{"accept", "application/json"}],
        "application/octet-stream",
        Body
    },
    case httpc:request(post, Request, http_options(), [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, ResponseBody}}
                when Status >= 200, Status < 300 ->
            {ok, #{
                <<"status">> => Status,
                <<"body">> => ResponseBody
            }};
        {ok, {{_, Status, _}, _Headers, ResponseBody}} ->
            {error, #{
                <<"status">> => Status,
                <<"body">> => ResponseBody
            }};
        {error, Reason} ->
            {error, Reason}
    end.

http_options() ->
    [{timeout, ?HTTP_TIMEOUT_MS}, {connect_timeout, ?HTTP_TIMEOUT_MS}].

submit_url(_Base, NodeMsg) ->
    configured_value(
        <<"ao-payment-submit-url">>,
        ao_payment_submit_url,
        configured_value(
            <<"ao-payment-mu-url">>,
            ao_payment_mu_url,
            ?DEFAULT_SUBMIT_URL,
            NodeMsg
        ),
        NodeMsg
    ).

normalize_url(URL0) ->
    URL = hb_util:bin(URL0),
    case binary:last(URL) of
        $/ -> binary:part(URL, 0, byte_size(URL) - 1);
        _ -> URL
    end.

withdrawal_key(Withdrawal) ->
    case hb_maps:get(<<"withdraw-id">>, Withdrawal, undefined, #{}) of
        undefined ->
            <<(hb_maps:get(<<"token">>, Withdrawal, undefined, #{}))/binary, ":",
                (hb_maps:get(<<"recipient">>, Withdrawal, undefined, #{}))/binary, ":",
                (hb_util:bin(hb_maps:get(<<"quantity">>, Withdrawal, undefined, #{})))/binary>>;
        WithdrawID ->
            hb_util:bin(WithdrawID)
    end.

withdraw_error(Status, Body) ->
    {error, #{ <<"status">> => Status, <<"body">> => Body }}.

wallet_opts(NodeMsg) ->
    Wallet =
        case configured_wallet(NodeMsg) of
            not_found ->
                hb:wallet(hb_opts:get(priv_key_location, <<"hyperbeam-key.json">>, NodeMsg));
            FoundWallet ->
                FoundWallet
        end,
    Operator = hb_util:human_id(ar_wallet:to_address(Wallet)),
    NodeMsg#{
        priv_wallet => Wallet,
        <<"priv-wallet">> => Wallet,
        operator => Operator,
        <<"operator">> => Operator
    }.

configured_wallet(Opts) when is_map(Opts) ->
    case maps:get(<<"priv-wallet">>, Opts, not_found) of
        not_found -> maps:get(priv_wallet, Opts, not_found);
        Wallet -> Wallet
    end;
configured_wallet(_Opts) ->
    not_found.

local_node(NodeMsg) ->
    hb_opts:get(
        ao_payment_node,
        <<"http://localhost:", (hb_util:bin(hb_opts:get(port, 8734, NodeMsg)))/binary>>,
        NodeMsg
    ).

ledger_route(Payment, NodeMsg) ->
    Ledger = hb_maps:get(<<"ledger">>, Payment, undefined, NodeMsg),
    case hb_maps:get(
        <<"ledger-path">>,
        Payment,
        configured_ledger_path(NodeMsg),
        NodeMsg
    ) of
        undefined -> <<"/", Ledger/binary, "~process@1.0">>;
        <<>> -> <<"/", Ledger/binary, "~process@1.0">>;
        Path -> normalize_route(Path)
    end.

normalize_route(Path0) ->
    Path = strip_trailing_slash(hb_util:bin(Path0)),
    case Path of
        <<"/", _/binary>> -> Path;
        _ -> <<"/", Path/binary>>
    end.

strip_trailing_slash(<<>>) ->
    <<>>;
strip_trailing_slash(<<"/">>) ->
    <<"/">>;
strip_trailing_slash(Path) ->
    case binary:last(Path) of
        $/ -> binary:part(Path, 0, byte_size(Path) - 1);
        _ -> Path
    end.

ledger_path(_Req, NodeMsg) ->
    configured_ledger_path(NodeMsg).

request_value(Key, Req, Default) ->
    case direct_get(Key, Req) of
        undefined -> Default;
        Value -> Value
    end.

configured_ledger_path(NodeMsg) ->
    configured_value(
        <<"ao-payment-ledger-path">>,
        ao_payment_ledger_path,
        undefined,
        NodeMsg
    ).

configured_value(BinaryKey, AtomKey, Default, NodeMsg) ->
    case direct_get(BinaryKey, NodeMsg) of
        undefined ->
            case direct_get(AtomKey, NodeMsg) of
                undefined -> Default;
                Value -> Value
            end;
        Value ->
            Value
    end.

settlement_timeout_ms(NodeMsg) ->
    positive_int_config(
        <<"ao-payment-settlement-timeout-ms">>,
        ao_payment_settlement_timeout_ms,
        ?DEFAULT_SETTLEMENT_TIMEOUT_MS,
        NodeMsg
    ).

settlement_poll_ms(NodeMsg) ->
    positive_int_config(
        <<"ao-payment-settlement-poll-ms">>,
        ao_payment_settlement_poll_ms,
        ?DEFAULT_SETTLEMENT_POLL_MS,
        NodeMsg
    ).

positive_int_config(BinaryKey, AtomKey, Default, NodeMsg) ->
    try hb_util:int(configured_value(BinaryKey, AtomKey, Default, NodeMsg)) of
        Value when Value > 0 -> Value;
        _ -> Default
    catch
        _:_ -> Default
    end.

non_negative_int(Value, Default) ->
    try hb_util:int(Value) of
        Int when Int >= 0 -> Int;
        _ -> Default
    catch
        _:_ -> Default
    end.

state_path(Kind, Key) ->
    Digest = hb_util:encode(crypto:hash(sha256, term_to_binary(Key))),
    hb_path:to_binary([<<"~ao-payment@1.11">>, <<"state">>, Kind, Digest]).

persistent_state_read(Path, Default, NodeMsg) ->
    Opts = hb_store:scope(NodeMsg, local),
    case hb_opts:get(store, no_viable_store, Opts) of
        no_viable_store ->
            {error, no_viable_store};
        Store ->
            case hb_store:read(Store, Path, Opts) of
                {ok, Encoded} when is_binary(Encoded) ->
                    decode_persistent_state(Encoded);
                not_found ->
                    {ok, Default};
                {error, not_found} ->
                    {ok, Default};
                {error, Reason} ->
                    {error, Reason};
                Other ->
                    {error, {unexpected_store_read, Other}}
            end
    end.

decode_persistent_state(Encoded) ->
    try binary_to_term(Encoded, [safe]) of
        {?STATE_TERM_TAG, Value} -> {ok, Value};
        _ -> {error, invalid_state_format}
    catch
        _:_ -> {error, invalid_state_encoding}
    end.

persistent_state_write(Path, Value, NodeMsg) ->
    Opts = hb_store:scope(NodeMsg, local),
    case hb_opts:get(store, no_viable_store, Opts) of
        no_viable_store ->
            {error, no_viable_store};
        Store ->
            Encoded = term_to_binary({?STATE_TERM_TAG, Value}, [compressed]),
            case hb_store:write(Store, #{ Path => Encoded }, Opts) of
                ok -> ok;
                {error, Reason} -> {error, Reason};
                Other -> {error, {unexpected_store_write, Other}}
            end
    end.

direct_get(Key, Map) when is_map(Map) ->
    maps:get(Key, Map, undefined);
direct_get(_Key, _Map) ->
    undefined.

payment_key(Payment) ->
    <<(hb_maps:get(<<"token">>, Payment, undefined, #{}))/binary, ":",
        (hb_maps:get(<<"message-id">>, Payment, undefined, #{}))/binary>>.

payment_status(Payment) when is_map(Payment) ->
    maps:get(<<"status">>, Payment, <<"imported">>);
payment_status(_) ->
    <<"imported">>.

tag_value(Tags, Name, NodeMsg) ->
    case lists:search(
        fun(Tag) ->
            hb_maps:get(<<"name">>, Tag, undefined, NodeMsg) =:= Name
        end,
        Tags
    ) of
        {value, Tag} -> hb_maps:get(<<"value">>, Tag, undefined, NodeMsg);
        false -> undefined
    end.

-ifdef(TEST).
verify_result_requires_debit_and_credit_test() ->
    Expected = #{
        <<"token">> => <<"ao-token">>,
        <<"message-id">> => <<"message-id">>,
        <<"ledger">> => <<"ledger">>,
        <<"deposit-address">> => <<"node-address">>,
        <<"sender">> => <<"sender">>,
        <<"quantity">> => <<"1">>,
        <<"requested-recipient">> => undefined
    },
    Debit = #{
        <<"Target">> => <<"sender">>,
        <<"Tags">> => [
            #{<<"name">> => <<"Action">>, <<"value">> => <<"Debit-Notice">>},
            #{<<"name">> => <<"Recipient">>, <<"value">> => <<"node-address">>},
            #{<<"name">> => <<"Quantity">>, <<"value">> => <<"1">>}
        ]
    },
    Credit = #{
        <<"Target">> => <<"node-address">>,
        <<"Tags">> => [
            #{<<"name">> => <<"Action">>, <<"value">> => <<"Credit-Notice">>},
            #{<<"name">> => <<"Sender">>, <<"value">> => <<"sender">>},
            #{<<"name">> => <<"Quantity">>, <<"value">> => <<"1">>}
        ]
    },
    ?assertMatch(
        {ok, #{ <<"recipient">> := <<"sender">>, <<"quantity">> := <<"1">> }},
        verify_result(#{<<"raw">> => #{<<"Messages">> => [Debit, Credit]}}, Expected, #{})
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 402 }},
        verify_result(#{<<"raw">> => #{<<"Messages">> => [Credit]}}, Expected, #{})
    ).

verify_rejects_missing_required_fields_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 500 }},
        verify(#{}, #{ <<"message-id">> => <<"message-id">> }, #{})
    ).

configured_payment_scope_rejects_request_override_test() ->
    Opts = #{
        <<"ao-payment-token">> => <<"configured-token">>,
        <<"ao-payment-ledger">> => <<"configured-ledger">>,
        <<"ao-payment-deposit-address">> => <<"configured-deposit">>,
        <<"ao-payment-ledger-path">> => <<"/ledger~node-process@1.0">>
    },
    ?assertMatch(
        {ok, _, _, _, <<"/ledger~node-process@1.0">>},
        configured_payment_scope(
            #{
                <<"token">> => <<"configured-token">>,
                <<"ledger">> => <<"configured-ledger">>,
                <<"deposit-address">> => <<"configured-deposit">>,
                <<"ledger-path">> => <<"/ledger~node-process@1.0">>
            },
            Opts
        )
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 400, <<"field">> := <<"deposit-address">> }},
        configured_payment_scope(
            #{<<"deposit-address">> => <<"caller-controlled-address">>},
            Opts
        )
    ).

verify_rejects_self_transfer_and_non_positive_quantity_before_fetch_test() ->
    Deposit = hb_util:encode(crypto:strong_rand_bytes(32)),
    Opts = #{
        <<"ao-payment-token">> => hb_util:encode(crypto:strong_rand_bytes(32)),
        <<"ao-payment-ledger">> => hb_util:encode(crypto:strong_rand_bytes(32)),
        <<"ao-payment-deposit-address">> => Deposit,
        <<"ao-payment-ledger-path">> => <<"/ledger~node-process@1.0">>
    },
    Request = #{
        <<"message-id">> => hb_util:encode(crypto:strong_rand_bytes(32)),
        <<"slot">> => 1,
        <<"sender">> => Deposit,
        <<"quantity">> => 1
    },
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        verify(#{}, Request, Opts)
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        verify(
            #{},
            Request#{
                <<"sender">> => hb_util:encode(crypto:strong_rand_bytes(32)),
                <<"quantity">> => 0
            },
            Opts
        )
    ).

charge_validation_requires_operator_and_single_account_test() ->
    Wallet = ar_wallet:new(),
    Operator = hb_util:human_id(ar_wallet:to_address(Wallet)),
    Payer = hb_util:encode(crypto:strong_rand_bytes(32)),
    Recipient = hb_util:encode(crypto:strong_rand_bytes(32)),
    Opts = #{
        priv_wallet => Wallet,
        <<"priv-wallet">> => Wallet,
        <<"operator">> => Operator,
        <<"p4-recipient">> => Recipient
    },
    Unsigned = #{
        <<"account">> => Payer,
        <<"recipient">> => Recipient,
        <<"quantity">> => 7
    },
    Signed = hb_message:commit(Unsigned, Opts),
    ?assertMatch(
        {error, #{ <<"status">> := 403 }},
        validate_charge_request(#{}, Unsigned, Opts)
    ),
    ?assertEqual(
        {ok, Payer, Recipient, 7},
        validate_charge_request(#{}, Signed, Opts)
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        validate_charge_request(
            #{},
            hb_message:commit(Unsigned#{<<"account">> => [Payer]}, Opts),
            Opts
        )
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        validate_charge_request(
            #{},
            hb_message:commit(maps:remove(<<"recipient">>, Unsigned), Opts),
            Opts
        )
    ),
    AttackerWallet = ar_wallet:new(),
    Attacker = hb_util:human_id(ar_wallet:to_address(AttackerWallet)),
    AttackerReq = hb_message:commit(
        Unsigned,
        #{ <<"priv-wallet">> => AttackerWallet }
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 403 }},
        validate_charge_request(#{ <<"operator">> => Attacker }, AttackerReq, Opts)
    ).

trusted_node_scope_ignores_base_overrides_test() ->
    Opts = #{
        <<"ao-payment-ledger-path">> => <<"/trusted~node-process@1.0">>,
        <<"ao-payment-reservation-amount">> => 2100
    },
    Base = #{
        <<"ledger-path">> => <<"/caller~node-process@1.0">>,
        <<"reservation-amount">> => 1
    },
    ?assertEqual(<<"/trusted~node-process@1.0">>, ledger_path(Base, Opts)),
    ?assertEqual(2100, reservation_amount(Base, Opts)),
    ?assertEqual(undefined, ledger_path(Base, #{})),
    ?assertEqual(0, reservation_amount(Base, #{})).

verify_schedule_matches_expected_transfer_test() ->
    Schedule = #{
        <<"edges">> => [
            #{
                <<"node">> => #{
                    <<"message">> => #{
                        <<"Id">> => <<"message-id">>,
                        <<"Tags">> => [
                            tag(<<"Action">>, <<"Transfer">>),
                            tag(<<"Recipient">>, <<"node-address">>),
                            tag(<<"Quantity">>, <<"1">>)
                        ]
                    },
                    <<"assignment">> => #{
                        <<"Tags">> => [tag(<<"Nonce">>, <<"7">>)]
                    }
                }
            }
        ]
    },
    Expected = #{
        <<"message-id">> => <<"message-id">>,
        <<"ledger">> => <<"ledger">>,
        <<"deposit-address">> => <<"node-address">>,
        <<"quantity">> => <<"1">>,
        <<"slot">> => <<"7">>
    },
    ?assertEqual(ok, verify_schedule(Schedule, Expected, #{})),
    ?assertMatch(
        {error, #{ <<"status">> := 402 }},
        verify_schedule(
            Schedule,
            Expected#{ <<"quantity">> => <<"2">> },
            #{}
        )
    ).

ledger_route_prefers_configured_path_test() ->
    ?assertEqual(
        <<"/ledger~node-process@1.0">>,
        ledger_route(
            #{
                <<"ledger">> => <<"ledger-id">>,
                <<"ledger-path">> => <<"ledger~node-process@1.0/">>
            },
            #{}
        )
    ).

ledger_route_falls_back_to_process_id_test() ->
    ?assertEqual(
        <<"/ledger-id~process@1.0">>,
        ledger_route(#{ <<"ledger">> => <<"ledger-id">> }, #{})
    ).

credit_to_payment_uses_sender_without_forwarded_recipient_test() ->
    Expected = payment_expected(undefined),
    Credit = credit_notice([]),
    ?assertMatch(
        {ok, #{ <<"recipient">> := <<"sender">> }},
        credit_to_payment(Credit, Expected, #{})
    ).

credit_to_payment_respects_forwarded_recipient_test() ->
    Expected = payment_expected(<<"local-recipient">>),
    Credit = credit_notice([tag(<<"X-HB-Recipient">>, <<"local-recipient">>)]),
    ?assertMatch(
        {ok, #{ <<"recipient">> := <<"local-recipient">> }},
        credit_to_payment(Credit, Expected, #{})
    ).

credit_to_payment_rejects_requested_recipient_mismatch_test() ->
    Expected = payment_expected(<<"local-recipient">>),
    Credit = credit_notice([tag(<<"X-HB-Recipient">>, <<"other-recipient">>)]),
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        credit_to_payment(Credit, Expected, #{})
    ).

read_ledger_balance_requires_recipient_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        read_ledger_balance(#{ <<"ledger">> => <<"missing">> }, #{})
    ).

normalize_balance_returns_error_for_non_integer_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 503 }},
        normalize_balance(<<"not-a-balance">>)
    ).

p4_balance_missing_ledger_path_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 500 }},
        balance(#{}, #{ <<"target">> => <<"alice">> }, #{})
    ).

p4_balance_missing_target_returns_zero_test() ->
    ?assertEqual(
        {ok, 0},
        balance(
            #{},
            #{},
            #{
                <<"ao-payment-ledger-path">> =>
                    <<"/ledger~node-process@1.0">>
            }
        )
    ).

p4_charge_missing_ledger_path_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 500 }},
        charge(#{}, #{}, #{})
    ).

p4_balance_target_uses_nested_request_target_test() ->
    ?assertEqual(
        <<"alice">>,
        balance_target(
            #{ <<"request">> => #{ <<"target">> => <<"alice">> } },
            #{}
        )
    ).

settlement_config_defaults_and_overrides_test() ->
    ?assertEqual(?DEFAULT_SETTLEMENT_TIMEOUT_MS, settlement_timeout_ms(#{})),
    ?assertEqual(
        42,
        settlement_timeout_ms(#{ <<"ao-payment-settlement-timeout-ms">> => <<"42">> })
    ),
    ?assertEqual(?DEFAULT_SETTLEMENT_POLL_MS, settlement_poll_ms(#{})),
    ?assertEqual(
        25,
        settlement_poll_ms(#{ ao_payment_settlement_poll_ms => 25 })
    ).

withdraw_accepts_private_secret_test() ->
    Recipient = hb_util:encode(crypto:strong_rand_bytes(32)),
    NodeMsg =
        hb_private:set(
            #{ <<"p4-recipient">> => Recipient },
            <<"ao-payment-withdraw-secret">>,
            <<"secret">>,
            #{}
        ),
    ?assertMatch(
        {ok, #{ <<"quantity">> := 7 }},
        validate_withdrawal(
            #{},
            #{
                <<"recipient">> => Recipient,
                <<"quantity">> => <<"7">>,
                <<"withdraw-secret">> => <<"secret">>
            },
            NodeMsg
        )
    ).

withdraw_rejects_unsigned_request_test() ->
    Operator = hb_util:encode(crypto:strong_rand_bytes(32)),
    ?assertMatch(
        {error, #{ <<"status">> := 403 }},
        validate_withdrawal(
            #{},
            #{
                <<"recipient">> => Operator,
                <<"quantity">> => <<"7">>
            },
            #{ <<"operator">> => Operator }
        )
    ).

withdraw_accepts_operator_signed_request_test() ->
    Wallet = ar_wallet:new(),
    Operator = hb_util:human_id(ar_wallet:to_address(Wallet)),
    NodeMsg = #{
        priv_wallet => Wallet,
        <<"priv-wallet">> => Wallet,
        <<"operator">> => Operator,
        <<"p4-recipient">> => Operator
    },
    Req =
        hb_message:commit(
            #{
                <<"recipient">> => Operator,
                <<"quantity">> => <<"7">>,
                <<"withdraw-id">> => <<"signed-withdrawal">>
            },
            NodeMsg
        ),
    ?assertMatch(
        {ok, #{ <<"quantity">> := 7 }},
        validate_withdrawal(#{}, Req, NodeMsg)
    ).

withdraw_rejects_non_operator_signed_request_test() ->
    Wallet = ar_wallet:new(),
    Operator = hb_util:encode(crypto:strong_rand_bytes(32)),
    NodeMsg = #{
        priv_wallet => Wallet,
        <<"priv-wallet">> => Wallet,
        <<"operator">> => Operator
    },
    Req =
        hb_message:commit(
            #{
                <<"recipient">> => Operator,
                <<"quantity">> => <<"7">>,
                <<"withdraw-id">> => <<"signed-withdrawal">>
            },
            NodeMsg
        ),
    ?assertMatch(
        {error, #{ <<"status">> := 403 }},
        validate_withdrawal(#{}, Req, NodeMsg)
    ).

withdraw_rejects_beneficiary_signer_destination_and_token_override_test() ->
    OperatorWallet = ar_wallet:new(),
    BeneficiaryWallet = ar_wallet:new(),
    Operator = hb_util:human_id(ar_wallet:to_address(OperatorWallet)),
    Beneficiary = hb_util:human_id(ar_wallet:to_address(BeneficiaryWallet)),
    OtherRecipient = hb_util:encode(crypto:strong_rand_bytes(32)),
    Token = hb_util:encode(crypto:strong_rand_bytes(32)),
    NodeMsg = #{
        priv_wallet => OperatorWallet,
        <<"priv-wallet">> => OperatorWallet,
        <<"operator">> => Operator,
        <<"p4-recipient">> => Beneficiary,
        <<"ao-payment-deposit-address">> => Beneficiary,
        <<"ao-payment-token">> => Token
    },
    Request = #{
        <<"recipient">> => Beneficiary,
        <<"quantity">> => 7,
        <<"withdraw-id">> => <<"guarded-withdrawal">>
    },
    BeneficiarySigned = hb_message:commit(
        Request,
        #{ <<"priv-wallet">> => BeneficiaryWallet }
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 403 }},
        validate_withdrawal(#{}, BeneficiarySigned, NodeMsg)
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 403 }},
        validate_withdrawal(
            #{},
            hb_message:commit(
                Request#{ <<"recipient">> => OtherRecipient },
                #{ <<"priv-wallet">> => OperatorWallet }
            ),
            NodeMsg
        )
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        validate_withdrawal(
            #{},
            hb_message:commit(
                Request#{
                    <<"token">> => hb_util:encode(crypto:strong_rand_bytes(32))
                },
                #{ <<"priv-wallet">> => OperatorWallet }
            ),
            NodeMsg
        )
    ),
    ?assertMatch(
        {ok, #{ <<"recipient">> := Beneficiary, <<"token">> := Token }},
        validate_withdrawal(
            #{},
            hb_message:commit(Request, #{ <<"priv-wallet">> => OperatorWallet }),
            NodeMsg
        )
    ).

withdrawal_state_serializes_and_persists_single_submission_test() ->
    Store = hb_test_utils:test_store(hb_store_volatile, <<"ao-payment-withdrawals">>),
    hb_store:start(Store),
    Wallet = ar_wallet:new(),
    Withdrawal = #{
        <<"token">> => hb_util:encode(crypto:strong_rand_bytes(32)),
        <<"recipient">> => hb_util:encode(crypto:strong_rand_bytes(32)),
        <<"quantity">> => 7,
        <<"withdraw-id">> => <<"single-submit">>,
        <<"submit-url">> => <<"https://mu.invalid">>
    },
    Opts = #{
        store => Store,
        <<"store">> => Store,
        priv_wallet => Wallet,
        <<"priv-wallet">> => Wallet
    },
    Key = withdrawal_key(Withdrawal),
    Counter = atomics:new(1, []),
    SubmitFun = fun(_Prepared, _NodeMsg) ->
        _ = atomics:add_get(Counter, 1, 1),
        timer:sleep(25),
        {ok, #{ <<"status">> => 202 }}
    end,
    Parent = self(),
    Ref = make_ref(),
    [
        spawn(fun() ->
            Result = with_withdrawal_lock(
                Key,
                fun() ->
                    submit_and_store_withdrawal(
                        Key,
                        Withdrawal,
                        Opts,
                        SubmitFun
                    )
                end
            ),
            Parent ! {Ref, Result}
        end)
     || _ <- lists:seq(1, 4)
    ],
    Results = [receive {Ref, Result} -> Result end || _ <- lists:seq(1, 4)],
    ?assertEqual(1, atomics:get(Counter, 1)),
    ?assertEqual(
        1,
        length([
            ok
         || {ok, #{ <<"status">> := <<"submitted">> }} <- Results
        ])
    ),
    ?assertEqual(
        3,
        length([
            ok
         || {ok, #{ <<"status">> := <<"already-submitted">> }} <- Results
        ])
    ),
    {ok, Persisted} = load_withdrawal(Key, Opts),
    ?assertEqual(<<"submitted">>, maps:get(<<"status">>, Persisted)),
    ?assertMatch(
        {error, #{ <<"status">> := 409 }},
        submit_and_store_withdrawal(
            Key,
            Withdrawal#{ <<"quantity">> => 8 },
            Opts,
            SubmitFun
        )
    ),
    ?assertEqual(1, atomics:get(Counter, 1)).

prepared_withdrawal_is_never_resubmitted_test() ->
    Store = hb_test_utils:test_store(hb_store_volatile, <<"ao-payment-withdrawal-retry">>),
    hb_store:start(Store),
    Wallet = ar_wallet:new(),
    Withdrawal = #{
        <<"token">> => hb_util:encode(crypto:strong_rand_bytes(32)),
        <<"recipient">> => hb_util:encode(crypto:strong_rand_bytes(32)),
        <<"quantity">> => 7,
        <<"withdraw-id">> => <<"prepared-withdrawal">>,
        <<"submit-url">> => <<"https://mu.invalid">>
    },
    Opts = #{
        store => Store,
        <<"store">> => Store,
        priv_wallet => Wallet,
        <<"priv-wallet">> => Wallet
    },
    Key = withdrawal_key(Withdrawal),
    Prepared = prepare_withdrawal(Withdrawal, Opts),
    ok = store_withdrawal(Key, Prepared, Opts),
    Counter = atomics:new(1, []),
    SubmitFun = fun(_PreparedAgain, _NodeMsg) ->
        _ = atomics:add_get(Counter, 1, 1),
        {ok, #{ <<"status">> => 202 }}
    end,
    ?assertMatch(
        {error, #{ <<"status">> := 503 }},
        submit_and_store_withdrawal(Key, Withdrawal, Opts, SubmitFun)
    ),
    ?assertEqual(0, atomics:get(Counter, 1)).

withdraw_posts_legacy_mu_test_() ->
    {timeout, 30, fun() ->
        {ok, _} = application:ensure_all_started(hackney),
        ok = hb_http:start(),
        ok = hb_http_client:init_prometheus(),
        Token = hb_util:encode(crypto:strong_rand_bytes(32)),
        Recipient = hb_util:encode(crypto:strong_rand_bytes(32)),
        Store = hb_test_utils:test_store(),
        Wallet = ar_wallet:new(),
        Opts0 = #{
            store => Store,
            <<"store">> => Store,
            priv_wallet => Wallet,
            <<"priv-wallet">> => Wallet
        },
        {ok, SubmitURL, MockHandle} =
            hb_mock_server:start([
                {
                    "/",
                    submit,
                    {202, <<"{\"message\":\"Processing DataItem\"}">>}
                }
            ]),
        NodeMsg = Opts0,
        try
            Prepared = prepare_withdrawal(
                #{
                    <<"token">> => Token,
                    <<"recipient">> => Recipient,
                    <<"quantity">> => 7,
                    <<"withdraw-id">> => <<"test-withdrawal">>,
                    <<"submit-url">> => SubmitURL
                },
                NodeMsg
            ),
            {ok, SubmitResult} = submit_prepared_withdrawal(Prepared, NodeMsg),
            Result = withdrawal_response(
                Prepared#{
                    <<"status">> => <<"submitted">>,
                    <<"submit-response">> => SubmitResult
                }
            ),
            [Captured] = hb_mock_server:get_requests(submit, 1, MockHandle),
            Headers = hb_maps:get(<<"headers">>, Captured, #{}, #{}),
            ?assertEqual(
                <<"application/octet-stream">>,
                hb_maps:get(<<"content-type">>, Headers, undefined, #{})
            ),
            RawTX =
                ar_bundles:deserialize(
                    hb_maps:get(<<"body">>, Captured, undefined, #{})
                ),
            ?assert(ar_bundles:verify_item(RawTX)),
            ?assertEqual(hb_util:decode(Token), RawTX#tx.target),
            ?assertEqual(<<"1984">>, RawTX#tx.data),
            RawTags = RawTX#tx.tags,
            ?assert(lists:member({<<"Data-Protocol">>, <<"ao">>}, RawTags)),
            ?assert(lists:member({<<"Variant">>, <<"ao.TN.1">>}, RawTags)),
            ?assert(lists:member({<<"Type">>, <<"Message">>}, RawTags)),
            ?assert(lists:member({<<"Action">>, <<"Transfer">>}, RawTags)),
            ?assert(lists:member({<<"Recipient">>, Recipient}, RawTags)),
            ?assert(lists:member({<<"Quantity">>, <<"7">>}, RawTags)),
            ?assertEqual(
                hb_util:human_id(RawTX#tx.id),
                hb_maps:get(<<"message-id">>, Result, undefined, NodeMsg)
            )
        after
            hb_mock_server:stop(MockHandle)
        end
    end}.

reservation_request_requires_p4_admission_target_test() ->
    Wallet = ar_wallet:new(),
    Account = hb_util:human_id(ar_wallet:to_address(Wallet)),
    Request = hb_message:commit(
        #{ <<"path">> => <<"/paid">> },
        #{ <<"priv-wallet">> => Wallet }
    ),
    ?assertEqual(
        none,
        reservation_request(Account, #{ <<"request">> => Request }, #{})
    ),
    ?assertMatch(
        {ok, _},
        reservation_request(
            Account,
            #{ <<"target">> => Account, <<"request">> => Request },
            #{}
        )
    ),
    ?assertEqual(
        invalid,
        reservation_request(
            Account,
            #{
                <<"target">> => hb_util:encode(crypto:strong_rand_bytes(32)),
                <<"request">> => Request
            },
            #{}
        )
    ).

reservation_serializes_concurrent_admission_and_persists_test() ->
    Store = hb_test_utils:test_store(hb_store_volatile, <<"ao-payment-reservations">>),
    hb_store:start(Store),
    Wallet = ar_wallet:new(),
    Account = hb_util:human_id(ar_wallet:to_address(Wallet)),
    LedgerPath = <<"/reservation-ledger~node-process@1.0">>,
    Opts = #{
        store => Store,
        <<"store">> => Store,
        <<"ao-payment-ledger-path">> => LedgerPath,
        <<"ao-payment-reservation-amount">> => 2100
    },
    Requests = [
        hb_message:commit(
            #{ <<"path">> => <<"/paid">>, <<"nonce">> => N },
            #{ <<"priv-wallet">> => Wallet }
        )
     || N <- lists:seq(1, 4)
    ],
    Parent = self(),
    Ref = make_ref(),
    [
        spawn(fun() ->
            Result = with_account_lock(
                LedgerPath,
                Account,
                fun() ->
                    reserve_balance(
                        #{},
                        Account,
                        2100,
                        #{ <<"target">> => Account, <<"request">> => Request },
                        Opts
                    )
                end
            ),
            Parent ! {Ref, Result}
        end)
     || Request <- Requests
    ],
    Results = [receive {Ref, Result} -> Result end || _ <- Requests],
    ?assertEqual(1, length([ok || {ok, true} <- Results])),
    ?assertEqual(3, length([ok || {ok, 0} <- Results])),
    RestartOpts = maps:without([ao_payment_imports, <<"ao-payment-imports">>], Opts),
    {ok, Persisted} = load_reservations(Account, RestartOpts),
    ?assertEqual(2100, reserved_total(Persisted)).

charging_record_persists_exact_signed_charge_test() ->
    Store = hb_test_utils:test_store(hb_store_volatile, <<"ao-payment-charging">>),
    hb_store:start(Store),
    OperatorWallet = ar_wallet:new(),
    Account = hb_util:encode(crypto:strong_rand_bytes(32)),
    Recipient = hb_util:encode(crypto:strong_rand_bytes(32)),
    Key = hb_util:encode(crypto:strong_rand_bytes(32)),
    Opts = #{
        store => Store,
        <<"store">> => Store,
        priv_wallet => OperatorWallet,
        <<"priv-wallet">> => OperatorWallet
    },
    Req = #{
        <<"account">> => Account,
        <<"recipient">> => Recipient,
        <<"quantity">> => 7
    },
    LedgerCharge = ledger_charge_request(Req, Opts),
    State = #{
        Key => #{
            <<"status">> => <<"reserved">>,
            <<"amount">> => 10,
            <<"expires-at">> => erlang:system_time(millisecond) + 60000
        }
    },
    {ok, _} = mark_reservation_charging(
        Account,
        Recipient,
        7,
        Key,
        LedgerCharge,
        20,
        3,
        State,
        Opts
    ),
    {ok, Persisted} = load_reservations(Account, Opts),
    Entry = maps:get(Key, Persisted),
    PersistedCharge = maps:get(<<"ledger-charge">>, Entry),
    ?assertEqual(20, maps:get(<<"payer-balance-before">>, Entry)),
    ?assertEqual(3, maps:get(<<"recipient-balance-before">>, Entry)),
    ?assertEqual(
        hb_message:id(LedgerCharge, all, Opts),
        hb_message:id(PersistedCharge, all, Opts)
    ),
    ?assert(prepared_charge_matches(Entry, Req, Account, 7, Opts)),
    ?assertNot(prepared_charge_matches(Entry, Req#{ <<"quantity">> => 8 }, Account, 8, Opts)),
    ?assertNot(
        prepared_charge_matches(
            Entry,
            Req#{ <<"recipient">> => hb_util:encode(crypto:strong_rand_bytes(32)) },
            Account,
            7,
            Opts
        )
    ).

charge_reconciliation_never_assumes_an_unchanged_or_self_balance_test() ->
    Reservation = #{
        <<"payer-balance-before">> => 20,
        <<"recipient-balance-before">> => 3
    },
    ?assert(charge_was_applied(
        <<"payer">>, <<"recipient">>, 7, 13, 10, Reservation, #{}
    )),
    ?assertNot(charge_was_applied(
        <<"payer">>, <<"recipient">>, 7, 20, 3, Reservation, #{}
    )),
    ?assertNot(charge_was_applied(
        <<"same">>, <<"same">>, 7, 20, 20, Reservation, #{}
    )).

same_request_cannot_reuse_active_reservation_test() ->
    Store = hb_test_utils:test_store(hb_store_volatile, <<"ao-payment-replay">>),
    hb_store:start(Store),
    ClientWallet = ar_wallet:new(),
    Account = hb_util:human_id(ar_wallet:to_address(ClientWallet)),
    LedgerPath = <<"/replay-ledger~node-process@1.0">>,
    Opts = #{
        store => Store,
        <<"store">> => Store,
        <<"ao-payment-ledger-path">> => LedgerPath,
        <<"ao-payment-reservation-amount">> => 2100
    },
    Request = hb_message:commit(
        #{ <<"path">> => <<"/paid">> },
        #{ <<"priv-wallet">> => ClientWallet }
    ),
    ?assertEqual(
        {ok, true},
        with_account_lock(
            LedgerPath,
            Account,
            fun() ->
                reserve_balance(
                    #{},
                    Account,
                    2100,
                    #{ <<"target">> => Account, <<"request">> => Request },
                    Opts
                )
            end
        )
    ),
    ?assertEqual(
        {ok, 0},
        reserve_balance(
            #{},
            Account,
            2100,
            #{ <<"target">> => Account, <<"request">> => Request },
            Opts
        )
    ).

import_record_survives_fresh_options_test() ->
    Store = hb_test_utils:test_store(hb_store_volatile, <<"ao-payment-imports">>),
    hb_store:start(Store),
    Opts = #{ store => Store, <<"store">> => Store },
    Key = <<"token:message">>,
    Payment = #{
        <<"status">> => <<"prepared">>,
        <<"message-id">> => <<"message">>,
        <<"credit-notice">> => #{ <<"signed">> => <<"same-bytes">> }
    },
    ?assertEqual(ok, store_import(Key, Payment, Opts)),
    ?assertEqual({ok, Payment}, load_import(Key, Opts)).

auto_withdraw_configuration_fails_before_local_charge_test() ->
    ?assertMatch(
        {error, #{
            <<"status">> := 500,
            <<"reason">> := <<"unsafe_auto_withdraw_configuration">>
        }},
        apply_charge(
            #{},
            #{},
            <<"/ledger~node-process@1.0">>,
            #{ <<"ao-payment-auto-withdraw">> => true }
        )
    ).

payment_expected(RequestedRecipient) ->
    #{
        <<"token">> => <<"ao-token">>,
        <<"message-id">> => <<"message-id">>,
        <<"ledger">> => <<"ledger">>,
        <<"deposit-address">> => <<"node-address">>,
        <<"sender">> => <<"sender">>,
        <<"quantity">> => <<"1">>,
        <<"requested-recipient">> => RequestedRecipient
    }.

credit_notice(ExtraTags) ->
    #{
        <<"Tags">> => [
            tag(<<"Reference">>, <<"notice-reference">>)
            | ExtraTags
        ]
    }.

tag(Name, Value) ->
    #{ <<"name">> => Name, <<"value">> => Value }.
-endif.
