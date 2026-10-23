-module(aopayment_p4_flow).
-export([run/0, run_payout/0, run_admission/0]).
-include_lib("hb/include/hb.hrl").

run() -> run(false).
run_payout() -> run(true).

run(AutoPayout) -> run(AutoPayout, 2, 2, 50, allow).

run_admission() ->
    ok = run(false, 2, 3, 50, deny),
    ok = run(false, 100, 3, 2, deny),
    ok = run(false, 100, 2, 2, allow),
    ok.

run(AutoPayout, Cap, Price, Credit, Expected) ->
    ensure_env("HB_PRELOADED_STORE"),
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(hb),
    HostWallet = ar_wallet:new(),
    HostAddress = hb_util:human_id(ar_wallet:to_address(HostWallet)),
    OperatorWallet = ar_wallet:new(),
    OperatorAddress = hb_util:human_id(ar_wallet:to_address(OperatorWallet)),
    AliceWallet = ar_wallet:new(),
    AliceAddress = hb_util:human_id(ar_wallet:to_address(AliceWallet)),
    BobWallet = ar_wallet:new(),
    BobAddress = hb_util:human_id(ar_wallet:to_address(BobWallet)),
    LedgerName =
        <<"aopayment-ledger-",
            (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    LedgerPath = <<"/~node-process@1.0/", LedgerName/binary>>,
    {ok, TokenScript} = file:read_file("scripts/hyper-token.lua"),
    {ok, P4Script} = file:read_file("scripts/hyper-token-p4.lua"),
    {Device, PackageOpts} = test_package_options(),
    {ok, MU, Mock} = hb_mock_server:start([
        {"/", payout, {202, <<"{\"message\":\"Processing DataItem\"}">>}}
    ]),
    Token = hb_util:encode(crypto:strong_rand_bytes(32)),
    Processor = #{
        <<"device">> => <<"p4@1.0">>,
        <<"ledger-device">> => Device,
        <<"pricing-device">> => <<"simple-pay@1.0">>,
        <<"ledger-path">> => LedgerPath
    },
    Node =
        hb_http_server:start_node(maps:merge(PackageOpts, #{
            <<"store">> => [hb_test_utils:test_store() | maps:get(<<"store">>, PackageOpts, [])],
            <<"priv-wallet">> => HostWallet,
            <<"port">> => 0,
            <<"p4-non-chargable-routes">> => [
                #{<<"template">> => <<"/~node-process@1.0/*">>},
                #{<<"template">> => <<"/~p4@1.0/balance">>}
            ],
            <<"on">> => #{
                <<"request">> => [Processor | maps:get(<<"request">>,
                    maps:get(<<"on">>, hb_opts:default_message_with_env()))],
                <<"response">> => Processor
            },
            <<"operator">> => HostAddress,
            <<"p4-recipient">> => HostAddress,
            <<"ao-payment-ledger-path">> => LedgerPath,
            <<"ao-payment-reservation-amount">> => Cap,
            <<"router-opts">> => #{<<"offered">> => [
                #{<<"template">> => <<"//greeting">>, <<"price">> => Price}]},
            <<"ao-payment-auto-withdraw">> => AutoPayout,
            <<"ao-payment-token">> => Token,
            <<"ao-payment-deposit-address">> => HostAddress,
            <<"ao-payment-withdraw-recipient">> => OperatorAddress,
            <<"ao-payment-submit-url">> => MU,
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
        })),
    Req = #{
        <<"path">> => <<"//greeting">>,
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
                                <<"quantity">> => Credit,
                                <<"recipient">> => BobAddress
                            },
                            #{<<"priv-wallet">> => AliceWallet}
                        )
                },
                #{<<"priv-wallet">> => HostWallet}
            ),
            #{}
        ),
    case Expected of
    deny ->
        {error, Denied} = hb_http:get(Node, BobReq, #{}),
        assert_equal(402, hb_maps:get(<<"status">>, Denied, undefined, #{}), admission_rejects_quote),
        {ok, Unchanged} = hb_http:get(Node, <<LedgerPath/binary, "/now/balance">>, #{}),
        assert_equal(Credit, hb_ao:get(BobAddress, Unchanged, #{}), rejected_request_not_debited),
        assert_equal([], hb_mock_server:get_requests(Mock, payout), rejected_request_not_paid);
    allow ->
    assert_equal({ok, <<"Hello, world!">>}, hb_http:get(Node, BobReq, #{}), bob_paid_request),
    {ok, Balances} = hb_http:get(Node, <<LedgerPath/binary, "/now/balance">>, #{}),
    assert_equal(Credit - Price, hb_ao:get(BobAddress, Balances, #{}), bob_balance_after_charge),
    assert_equal(2, hb_ao:get(HostAddress, Balances, #{}), node_clearing_account_receives_charge),
    assert_match(
        {error, '_'},
        hb_http:get(Node, BobReq, #{}),
        repeated_paid_request_is_not_reexecuted
    ),
    {ok, ReplayBalances} = hb_http:get(Node, <<LedgerPath/binary, "/now/balance">>, #{}),
    assert_equal(Credit - Price, hb_ao:get(BobAddress, ReplayBalances, #{}), replay_does_not_recharge),
    assert_equal(
        2,
        hb_ao:get(HostAddress, ReplayBalances, #{}),
        replay_does_not_recredit_node
    ),
    BobBalanceReq =
        hb_message:commit(
            #{<<"path">> => <<"/~p4@1.0/balance">>},
            #{<<"priv-wallet">> => BobWallet}
        ),
    assert_equal({ok, Credit - Price}, hb_http:get(Node, BobBalanceReq, #{}), p4_balance_uses_request_signer),
    case AutoPayout of
        true ->
            [Captured] = hb_mock_server:get_requests(payout, 1, Mock),
            Item = ar_bundles:deserialize(maps:get(<<"body">>, Captured)),
            assert_equal(true, ar_bundles:verify_item(Item), payout_signature),
            assert_equal(hb_util:decode(Token), Item#tx.target, payout_token),
            assert_equal(HostAddress,
                hb_util:human_id(ar_wallet:to_address(Item#tx.owner, Item#tx.signature_type)),
                payout_from_node_wallet),
            assert_equal(true, lists:member({<<"Recipient">>, OperatorAddress}, Item#tx.tags), payout_beneficiary),
            assert_equal(true, lists:member({<<"Quantity">>, <<"2">>}, Item#tx.tags), payout_exact_charge);
        false -> assert_equal([], hb_mock_server:get_requests(Mock, payout), default_no_payout)
    end
    end,
    hb_mock_server:stop(Mock),
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

%% Optional immutable package pins let the same HTTP flow test a local candidate
%% without replacing or modifying the host's preloaded device index.
test_package_options() ->
    case os:getenv("AOPAYMENT_TEST_PACKAGE") of
        false -> {<<"ao-payment@1.11">>, #{}};
        Metadata ->
            {ok, Raw} = file:read_file(Metadata),
            P = hb_json:decode(Raw),
            Spec = maps:get(<<"ao-payment@1.11">>, maps:get(<<"specs">>, P)),
            [Impl] = maps:get(<<"impls">>, P),
            {Spec, #{
                <<"trusted-devices">> => #{ Spec => Impl },
                <<"store">> => [#{
                    <<"store-module">> => hb_store_lmdb,
                    <<"name">> => list_to_binary(os:getenv("AOPAYMENT_TEST_STORE")),
                    <<"read-only">> => true,
                    <<"capacity">> => 1073741824
                }]
            }}
    end.
