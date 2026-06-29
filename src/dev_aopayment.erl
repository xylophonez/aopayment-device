%%% @doc Import verified AO token payments into a local HyperBEAM payment
%%% ledger. This device expects production AO token transfers of the form:
%%%
%%%     Action=Transfer, Recipient=node-deposit-address, Quantity=raw-units
%%%
%%% It verifies the resulting `Debit-Notice' and `Credit-Notice' from AO
%%% mainnet state before scheduling a local `Credit-Notice' into the configured
%%% ledger process.
-module(dev_aopayment).
-implements(<<"ao-payment@1.0">>).
-export([ingest/3, verify/3, withdraw/3, balance/3, charge/3]).
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

%% @doc Verify and import an AO token payment into the local ledger.
ingest(Base, Req, NodeMsg) ->
    case verify(Base, Req, NodeMsg) of
        {ok, Payment} ->
            PaymentKey = payment_key(Payment),
            Imports = hb_opts:get(ao_payment_imports, #{}, NodeMsg),
            case maps:find(PaymentKey, Imports) of
                {ok, Existing} ->
                    case payment_status(Existing) of
                        <<"scheduled">> ->
                            settle_import(PaymentKey, Existing, Imports, NodeMsg);
                        <<"imported">> ->
                            {ok, Existing#{ <<"status">> => <<"already-imported">> }};
                        <<"already-imported">> ->
                            {ok, Existing};
                        _ ->
                            {ok, Existing#{ <<"status">> => <<"already-imported">> }}
                    end;
                error ->
                    case schedule_payment_import(Payment, NodeMsg) of
                        {ok, PendingPayment} ->
                            PendingImports = store_import(
                                PaymentKey,
                                PendingPayment,
                                Imports,
                                NodeMsg
                            ),
                            settle_import(
                                PaymentKey,
                                PendingPayment,
                                PendingImports,
                                NodeMsg
                            );
                        Error ->
                            Error
                    end
            end;
        Error ->
            Error
    end.

%% @doc Submit a real AO transfer from the node wallet to the configured
%% beneficiary. This is guarded by either a boot-generated secret or a verified
%% operator-signed request so the route is not an arbitrary signing endpoint
%% when exposed over HTTP.
withdraw(Base, Req, NodeMsg) ->
    case validate_withdrawal(Base, Req, NodeMsg) of
        {ok, Withdrawal} ->
            Key = withdrawal_key(Withdrawal),
            Withdrawals = hb_opts:get(ao_payment_withdrawals, #{}, NodeMsg),
            submit_and_store_withdrawal(Key, Withdrawal, Withdrawals, NodeMsg);
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
            read_p4_ledger_balance_at(LedgerPath, Target, ledger_resolve_opts(NodeMsg))
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
            LedgerRoute = normalize_route(LedgerPath),
            LedgerOpts = ledger_resolve_opts(NodeMsg),
            case hb_ao:resolve(
                #{
                    <<"path">> => <<"(", LedgerRoute/binary, ")/push">>,
                    <<"method">> => <<"POST">>,
                    <<"body">> => Req
                },
                LedgerOpts
            ) of
                {ok, Result} ->
                    case auto_withdraw_after_charge(Base, Req, NodeMsg) of
                        {ok, _WithdrawalResult} -> {ok, Result};
                        {error, Error} -> {error, Error}
                    end;
                Error ->
                    Error
            end
    end.

%% @doc Verify that an AO message produced matching token debit/credit notices.
verify(_Base, Req, NodeMsg) ->
    TokenDefault =
        configured_value(
            <<"ao-payment-token">>,
            ao_payment_token,
            ?DEFAULT_AO_TOKEN,
            NodeMsg
        ),
    LedgerDefault =
        configured_value(
            <<"ao-payment-ledger">>,
            ao_payment_ledger,
            undefined,
            NodeMsg
        ),
    Token = request_value(<<"token">>, Req, TokenDefault),
    Ledger = request_value(<<"ledger">>, Req, LedgerDefault),
    DepositDefault =
        case configured_value(
            <<"ao-payment-deposit-address">>,
            ao_payment_deposit_address,
            undefined,
            NodeMsg
        ) of
            undefined -> configured_value(<<"operator">>, operator, Ledger, NodeMsg);
            Address -> Address
        end,
    DepositAddress =
        request_value(<<"deposit-address">>, Req, DepositDefault),
    MessageID =
        case request_value(<<"message-id">>, Req, undefined) of
            undefined -> request_value(<<"id">>, Req, undefined);
            ID -> ID
        end,
    Slot = request_value(<<"slot">>, Req, undefined),
    Sender = request_value(<<"sender">>, Req, undefined),
    Quantity = hb_util:bin(request_value(<<"quantity">>, Req, undefined)),
    RequestedRecipient = request_value(<<"recipient">>, Req, undefined),
    case lists:any(fun(V) -> V =:= undefined orelse V =:= <<"undefined">> end,
        [Token, Ledger, DepositAddress, MessageID, Slot, Sender, Quantity])
    of
        true ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"Missing token, ledger, deposit-address, message-id, slot, sender, or quantity.">>
            }};
        false ->
            case fetch_schedule(Token, Slot, NodeMsg) of
                {ok, Result} ->
                    LedgerPath = ledger_path(Req, NodeMsg),
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
            end
    end.

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

schedule_payment_import(Payment, NodeMsg) ->
    case read_ledger_balance(Payment, NodeMsg) of
        {ok, BeforeBalance} ->
            case schedule_credit_notice(Payment, NodeMsg) of
                {ok, _ScheduleResult} ->
                    Quantity =
                        hb_util:int(
                            hb_maps:get(<<"quantity">>, Payment, undefined, NodeMsg)
                        ),
                    {ok, Payment#{
                        <<"status">> => <<"scheduled">>,
                        <<"balance-before">> => BeforeBalance,
                        <<"expected-balance">> => BeforeBalance + Quantity
                    }};
                {error, Reason} ->
                    payment_import_error(
                        502,
                        <<"Unable to schedule AO payment credit into local ledger.">>,
                        Reason
                    )
            end;
        Error ->
            Error
    end.

settle_import(PaymentKey, PendingPayment, Imports, NodeMsg) ->
    case await_imported_payment(PendingPayment, NodeMsg) of
        {ok, ImportedPayment} ->
            store_import(PaymentKey, ImportedPayment, Imports, NodeMsg),
            {ok, ImportedPayment};
        Error ->
            Error
    end.

store_import(PaymentKey, Payment, Imports, NodeMsg) ->
    NewImports = Imports#{ PaymentKey => Payment },
    hb_http_server:set_opts(
        #{},
        NodeMsg#{
            ao_payment_imports => NewImports,
            <<"ao-payment-imports">> => NewImports
        }
    ),
    NewImports.

submit_and_store_withdrawal(Key, Withdrawal, Withdrawals, NodeMsg) ->
    case maps:find(Key, Withdrawals) of
        {ok, Existing} ->
            {ok, Existing#{ <<"status">> => <<"already-submitted">> }};
        error ->
            case submit_withdrawal(Withdrawal, NodeMsg) of
                {ok, Result} ->
                    Stored = Result#{ <<"status">> => <<"submitted">> },
                    NewWithdrawals = Withdrawals#{ Key => Stored },
                    hb_http_server:set_opts(
                        #{},
                        NodeMsg#{
                            ao_payment_withdrawals => NewWithdrawals,
                            <<"ao-payment-withdrawals">> => NewWithdrawals
                        }
                    ),
                    {ok, Stored};
                Error ->
                    Error
            end
    end.

auto_withdraw_after_charge(Base, Req, NodeMsg) ->
    case auto_withdraw_enabled(Base, NodeMsg) of
        false ->
            {ok, skipped};
        true ->
            case auto_withdrawal_from_charge(Base, Req, NodeMsg) of
                {ok, Withdrawal} ->
                    Key = withdrawal_key(Withdrawal),
                    Withdrawals = hb_opts:get(ao_payment_withdrawals, #{}, NodeMsg),
                    submit_and_store_withdrawal(Key, Withdrawal, Withdrawals, NodeMsg);
                Error ->
                    Error
            end
    end.

auto_withdraw_enabled(Base, NodeMsg) ->
    enabled(
        hb_maps:get(
            <<"auto-withdraw">>,
            Base,
            configured_value(
                <<"ao-payment-auto-withdraw">>,
                ao_payment_auto_withdraw,
                false,
                NodeMsg
            ),
            NodeMsg
        )
    ).

auto_withdrawal_from_charge(Base, Req, NodeMsg) ->
    Token =
        hb_maps:get(
            <<"withdraw-token">>,
            Base,
            configured_value(
                <<"ao-payment-token">>,
                ao_payment_token,
                ?DEFAULT_AO_TOKEN,
                NodeMsg
            ),
            NodeMsg
        ),
    Recipient =
        hb_maps:get(
            <<"withdraw-recipient">>,
            Base,
            configured_value(
                <<"ao-payment-withdraw-recipient">>,
                ao_payment_withdraw_recipient,
                undefined,
                NodeMsg
            ),
            NodeMsg
        ),
    Quantity0 = direct_get(<<"quantity">>, Req),
    case {Recipient, parse_positive_quantity(Quantity0)} of
        {undefined, _} ->
            withdraw_error(400, <<"Missing AO payment auto-withdraw recipient.">>);
        {_, {error, _}} ->
            withdraw_error(400, <<"Invalid AO payment auto-withdraw quantity.">>);
        {_, {ok, Quantity}} ->
            {ok, #{
                <<"token">> => hb_util:human_id(Token),
                <<"recipient">> => hb_util:human_id(Recipient),
                <<"quantity">> => Quantity,
                <<"withdraw-id">> =>
                    auto_withdrawal_key(Req, Quantity, Recipient, NodeMsg),
                <<"submit-url">> => submit_url(Base, NodeMsg)
            }}
    end.

auto_withdrawal_key(Req, Quantity, Recipient, NodeMsg) ->
    BaseKey =
        try hb_message:id(Req, all, NodeMsg)
        catch
            _:_ ->
                hb_util:encode(crypto:hash(sha256, term_to_binary(Req)))
        end,
    <<"p4:", BaseKey/binary, ":", (hb_util:bin(Quantity))/binary, ":",
        (hb_util:human_id(Recipient))/binary>>.

schedule_credit_notice(Payment, NodeMsg) ->
    Opts = wallet_opts(NodeMsg),
    Ledger = hb_maps:get(<<"ledger">>, Payment, undefined, NodeMsg),
    LedgerRoute = ledger_route(Payment, NodeMsg),
    CreditNotice =
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
        ),
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
    LedgerRoute = normalize_route(LedgerPath),
    BalancePath = <<LedgerRoute/binary, "/now/balance">>,
    case hb_ao:resolve(#{ <<"path">> => BalancePath }, ResolveOpts) of
        {ok, Balances} when is_map(Balances) ->
            normalize_balance(hb_ao:get(Recipient, Balances, 0, ResolveOpts));
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
    try hb_util:human_id(Target)
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
            <<"AO payment was verified and scheduled, but local ledger balance did not settle before timeout.">>,
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

withdraw_authorized_signers(Base, NodeMsg) ->
    lists:usort(
        [
            Signer
         || Signer <- [
                normalize_target(hb_maps:get(<<"settlement-account">>, Base, undefined, NodeMsg)),
                normalize_target(hb_maps:get(<<"operator">>, Base, undefined, NodeMsg)),
                normalize_target(hb_maps:get(<<"p4-recipient">>, Base, undefined, NodeMsg)),
                normalize_target(hb_maps:get(<<"ao-payment-deposit-address">>, Base, undefined, NodeMsg)),
                normalize_target(configured_value(<<"operator">>, operator, undefined, NodeMsg)),
                normalize_target(configured_value(<<"p4-recipient">>, p4_recipient, undefined, NodeMsg)),
                normalize_target(
                    configured_value(
                        <<"ao-payment-deposit-address">>,
                        ao_payment_deposit_address,
                        undefined,
                        NodeMsg
                    )
                )
            ],
            Signer =/= undefined
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
        hb_maps:get(
            <<"token">>,
            Base,
            hb_opts:get(ao_payment_token, ?DEFAULT_AO_TOKEN, NodeMsg),
            NodeMsg
        ),
    Token = request_value(<<"token">>, Req, TokenDefault),
    Recipient = direct_get(<<"recipient">>, Req),
    Quantity0 = direct_get(<<"quantity">>, Req),
    WithdrawID = direct_get(<<"withdraw-id">>, Req),
    case {Recipient, parse_positive_quantity(Quantity0)} of
        {undefined, _} ->
            withdraw_error(400, <<"Missing withdrawal recipient.">>);
        {_, {error, _}} ->
            withdraw_error(400, <<"Invalid withdrawal quantity.">>);
        {_, {ok, Quantity}} ->
            AllowedRecipient = allowed_withdraw_recipient(Base, NodeMsg),
            case AllowedRecipient =:= undefined
                orelse hb_util:human_id(AllowedRecipient) =:=
                    hb_util:human_id(Recipient)
            of
                true ->
                    {ok, #{
                        <<"token">> => hb_util:human_id(Token),
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
    end.

withdraw_secret(NodeMsg) ->
    hb_private:get(
        <<"ao-payment-withdraw-secret">>,
        NodeMsg,
        hb_private:get(<<"withdraw-secret">>, NodeMsg, undefined, NodeMsg),
        NodeMsg
    ).

allowed_withdraw_recipient(Base, NodeMsg) ->
    hb_opts:get(
        ao_payment_withdraw_recipient,
        hb_maps:get(<<"withdraw-recipient">>, Base, undefined, NodeMsg),
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

submit_withdrawal(Withdrawal, NodeMsg) ->
    Opts = wallet_opts(NodeMsg),
    Token = hb_maps:get(<<"token">>, Withdrawal, ?DEFAULT_AO_TOKEN, NodeMsg),
    Recipient = hb_maps:get(<<"recipient">>, Withdrawal, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Withdrawal, undefined, NodeMsg),
    Msg =
        hb_message:commit(
            #{
                <<"target">> => Token,
                <<"data">> => <<"1984">>,
                <<"Data-Protocol">> => <<"ao">>,
                <<"Variant">> => <<"ao.TN.1">>,
                <<"Type">> => <<"Message">>,
                <<"Action">> => <<"Transfer">>,
                <<"Recipient">> => Recipient,
                <<"Quantity">> => hb_util:bin(Quantity),
                <<"Content-Type">> => <<"text/plain">>,
                <<"SDK">> => <<"hyperbeam-lapee">>
            },
            Opts,
            <<"ans104@1.0">>
        ),
    MessageID = hb_message:id(Msg, signed, Opts),
    case post_legacy_mu(
        hb_maps:get(<<"submit-url">>, Withdrawal, ?DEFAULT_SUBMIT_URL, NodeMsg),
        Msg,
        Opts
    ) of
        {ok, SubmitResult} ->
            {ok, #{
                <<"message-id">> => MessageID,
                <<"token">> => Token,
                <<"recipient">> => Recipient,
                <<"quantity">> => Quantity,
                <<"submit-response">> => SubmitResult
            }};
        {error, Reason} ->
            withdraw_fetch_error(Reason)
    end.

post_legacy_mu(SubmitURL0, Msg, Opts) ->
    SubmitURL = normalize_url(SubmitURL0),
    Item = hb_message:convert(Msg, <<"ans104@1.0">>, Opts),
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

submit_url(Base, NodeMsg) ->
    Configured =
        hb_opts:get(
            ao_payment_submit_url,
            hb_opts:get(ao_payment_mu_url, ?DEFAULT_SUBMIT_URL, NodeMsg),
            NodeMsg
        ),
    hb_maps:get(
        <<"submit-url">>,
        Base,
        hb_maps:get(<<"mu-url">>, Base, Configured, NodeMsg),
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

withdraw_fetch_error(Reason) ->
    {error, #{
        <<"status">> => 502,
        <<"body">> => <<"Unable to submit AO withdrawal to AO endpoint.">>,
        <<"reason">> => format_reason(Reason)
    }}.

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

ledger_path(Req, NodeMsg) ->
    case direct_get(<<"ledger-path">>, Req) of
        undefined -> configured_ledger_path(NodeMsg);
        Path -> Path
    end.

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
        {error, #{ <<"status">> := 400 }},
        verify(#{}, #{ <<"message-id">> => <<"message-id">> }, #{})
    ).

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
        balance(#{ <<"ledger-path">> => <<"/ledger~node-process@1.0">> }, #{}, #{})
    ).

p4_charge_missing_ledger_path_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 500 }},
        charge(#{}, #{}, #{})
    ).

p4_auto_withdrawal_uses_configured_recipient_test() ->
    Token = hb_util:encode(crypto:strong_rand_bytes(32)),
    Recipient = hb_util:encode(crypto:strong_rand_bytes(32)),
    NodeMsg = #{
        <<"ao-payment-auto-withdraw">> => true,
        <<"ao-payment-token">> => Token,
        <<"ao-payment-withdraw-recipient">> => Recipient
    },
    Req = #{ <<"quantity">> => 7, <<"account">> => <<"payer">> },
    ?assertEqual(true, auto_withdraw_enabled(#{}, NodeMsg)),
    {ok, Withdrawal} = auto_withdrawal_from_charge(#{}, Req, NodeMsg),
    ?assertEqual(Token, maps:get(<<"token">>, Withdrawal)),
    ?assertEqual(Recipient, maps:get(<<"recipient">>, Withdrawal)),
    ?assertEqual(7, maps:get(<<"quantity">>, Withdrawal)),
    ?assertMatch(<<"p4:", _/binary>>, maps:get(<<"withdraw-id">>, Withdrawal)).

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
    NodeMsg =
        hb_private:set(
            #{},
            <<"ao-payment-withdraw-secret">>,
            <<"secret">>,
            #{}
        ),
    ?assertMatch(
        {ok, #{ <<"quantity">> := 7 }},
        validate_withdrawal(
            #{},
            #{
                <<"recipient">> => hb_util:encode(crypto:strong_rand_bytes(32)),
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
            {ok, Result} =
                submit_withdrawal(
                    #{
                        <<"token">> => Token,
                        <<"recipient">> => Recipient,
                        <<"quantity">> => 7,
                        <<"withdraw-id">> => <<"test-withdrawal">>,
                        <<"submit-url">> => SubmitURL
                    },
                    NodeMsg
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
            RawTags = RawTX#tx.tags,
            ?assert(lists:member({<<"Data-Protocol">>, <<"ao">>}, RawTags)),
            ?assert(lists:member({<<"Variant">>, <<"ao.TN.1">>}, RawTags)),
            ?assert(lists:member({<<"Type">>, <<"Message">>}, RawTags)),
            ?assert(lists:member({<<"Action">>, <<"Transfer">>}, RawTags)),
            ?assert(lists:member({<<"Recipient">>, Recipient}, RawTags)),
            ?assert(lists:member({<<"Quantity">>, <<"7">>}, RawTags)),
            Submitted =
                hb_message:convert(
                    ar_bundles:deserialize(
                        hb_maps:get(<<"body">>, Captured, undefined, #{})
                    ),
                    <<"structured@1.0">>,
                    <<"ans104@1.0">>,
                    NodeMsg
                ),
            ?assert(hb_message:verify(Submitted, all, NodeMsg)),
            ?assertEqual(Token, hb_maps:get(<<"target">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"ao">>, hb_maps:get(<<"data-protocol">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"ao.TN.1">>, hb_maps:get(<<"variant">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"Message">>, hb_maps:get(<<"type">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"Transfer">>, hb_maps:get(<<"action">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(Recipient, hb_maps:get(<<"recipient">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"7">>, hb_maps:get(<<"quantity">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(
                hb_message:id(Submitted, signed, NodeMsg),
                hb_maps:get(<<"message-id">>, Result, undefined, NodeMsg)
            )
        after
            hb_mock_server:stop(MockHandle)
        end
    end}.

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
