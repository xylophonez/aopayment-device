-module(aopayment_p4_flow).
-export([run/0]).

run() ->
    ensure_env("HB_PRELOADED_STORE"),
    ensure_env("HB_PRELOADED_DEVICES_INDEX"),
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(hb),
    HostWallet = ar_wallet:new(),
    HostAddress = hb_util:human_id(HostWallet),
    OperatorWallet = ar_wallet:new(),
    OperatorAddress = hb_util:human_id(OperatorWallet),
    AliceWallet = ar_wallet:new(),
    AliceAddress = hb_util:human_id(AliceWallet),
    BobWallet = ar_wallet:new(),
    BobAddress = hb_util:human_id(BobWallet),
    LedgerName =
        <<"aopayment-ledger-",
            (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    LedgerPath = <<"/", LedgerName/binary, "~node-process@1.0">>,
    {ok, TokenScript} = file:read_file("scripts/hyper-token.lua"),
    {ok, P4Script} = file:read_file("scripts/hyper-token-p4.lua"),
    Processor = #{
        <<"device">> => <<"p4@1.0">>,
        <<"ledger-device">> => <<"ao-payment@1.0">>,
        <<"pricing-device">> => <<"simple-pay@1.0">>,
        <<"ledger-path">> => LedgerPath
    },
    Node =
        hb_http_server:start_node(#{
            <<"store">> => [hb_test_utils:test_store()],
            <<"priv-wallet">> => HostWallet,
            <<"port">> => 0,
            <<"p4-non-chargable-routes">> => [
                #{<<"template">> => <<"/*~node-process@1.0/*">>},
                #{<<"template">> => <<"/~p4@1.0/balance">>}
            ],
            <<"on">> => #{
                <<"request">> => Processor,
                <<"response">> => Processor
            },
            <<"operator">> => OperatorAddress,
            <<"node-processes">> => #{
                LedgerName => #{
                    <<"device">> => <<"process@1.0">>,
                    <<"execution-device">> => <<"lua@5.3a">>,
                    <<"scheduler-device">> => <<"scheduler@1.0">>,
                    <<"module">> => [
                        #{
                            <<"content-type">> => <<"text/x-lua">>,
                            <<"name">> => <<"scripts/hyper-token.lua">>,
                            <<"body">> => TokenScript
                        },
                        #{
                            <<"content-type">> => <<"text/x-lua">>,
                            <<"name">> => <<"scripts/hyper-token-p4.lua">>,
                            <<"body">> => P4Script
                        }
                    ],
                    <<"balance">> => #{AliceAddress => 100},
                    <<"admin">> => HostAddress
                }
            }
        }),
    Req = #{
        <<"path">> => <<"/greeting">>,
        <<"greeting">> => <<"Hello, world!">>
    },
    BobReq = hb_message:commit(Req, #{<<"priv-wallet">> => BobWallet}),
    assert_match({error, '_'}, hb_http:get(Node, BobReq, #{}), bob_starts_unfunded),
    {ok, _TopupRes} =
        hb_http:post(
            Node,
            hb_message:commit(
                #{
                    <<"path">> => <<LedgerPath/binary, "/schedule">>,
                    <<"body">> =>
                        hb_message:commit(
                            #{
                                <<"path">> => <<"transfer">>,
                                <<"quantity">> => 50,
                                <<"recipient">> => BobAddress
                            },
                            #{<<"priv-wallet">> => AliceWallet}
                        )
                },
                #{<<"priv-wallet">> => HostWallet}
            ),
            #{}
        ),
    assert_equal({ok, <<"Hello, world!">>}, hb_http:get(Node, BobReq, #{}), bob_paid_request),
    {ok, Balances} = hb_http:get(Node, <<LedgerPath/binary, "/now/balance">>, #{}),
    assert_equal(48, hb_ao:get(BobAddress, Balances, #{}), bob_balance_after_charge),
    assert_equal(2, hb_ao:get(OperatorAddress, Balances, #{}), operator_receives_charge),
    BobBalanceReq =
        hb_message:commit(
            #{<<"path">> => <<"/~p4@1.0/balance">>},
            #{<<"priv-wallet">> => BobWallet}
        ),
    assert_equal({ok, 48}, hb_http:get(Node, BobBalanceReq, #{}), p4_balance_uses_request_signer),
    io:format(
        "aopayment p4 flow ok: ledger=~s alice=~s bob=~s operator=~s~n",
        [LedgerPath, AliceAddress, BobAddress, OperatorAddress]
    ),
    ok.

ensure_env(Name) ->
    case os:getenv(Name) of
        false -> error({missing_env, Name});
        _ -> ok
    end.

assert_equal(Expected, Actual, Label) ->
    case Actual of
        Expected -> ok;
        _ -> error({assert_equal_failed, Label, Expected, Actual})
    end.

assert_match({error, '_'}, {error, _}, _Label) ->
    ok;
assert_match(Expected, Actual, Label) ->
    assert_equal(Expected, Actual, Label).
