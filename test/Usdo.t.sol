// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.22;

// LZ
import {
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {OFTMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTMsgCodec.sol";
import {BytesLib} from "solidity-bytes-utils/contracts/BytesLib.sol";
import {Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

// External
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@boringcrypto/boring-solidity/contracts/libraries/BoringERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// Tapioca
import {
    ITapiocaOptionBroker,
    ITapiocaOptionBrokerCrossChain
} from "tapioca-periph/interfaces/tap-token/ITapiocaOptionBroker.sol";
import {
    TapiocaOmnichainEngineHelper,
    PrepareLzCallData,
    PrepareLzCallReturn,
    ComposeMsgData,
    LZSendParam,
    RemoteTransferMsg
} from "tapioca-periph/tapiocaOmnichainEngine/extension/TapiocaOmnichainEngineHelper.sol";
import {
    IUsdo,
    UsdoInitStruct,
    UsdoModulesInitStruct,
    ExerciseOptionsMsg,
    YieldBoxApproveAssetMsg,
    YieldBoxApproveAllMsg,
    MarketPermitActionMsg,
    MarketRemoveAssetMsg,
    IRemoveAndRepay,
    MarketLendOrRepayMsg
} from "tapioca-periph/interfaces/oft/IUsdo.sol";
import {
    IUSDOBase,
    ILeverageSwapData,
    ILeverageExternalContractsData,
    IRemoveAndRepay,
    ILendOrRepayParams
} from "tapioca-periph/interfaces/bar/IUSDO.sol";
import {ITapiocaOptionLiquidityProvision} from
    "tapioca-periph/interfaces/tap-token/ITapiocaOptionLiquidityProvision.sol";
import {ERC20PermitStruct, ERC20PermitApprovalMsg} from "tapioca-periph/interfaces/periph/ITapiocaOmnichainEngine.sol";
import {ITapiocaOFT, IBorrowParams, IRemoveParams} from "tapioca-periph/interfaces/tap-token/ITapiocaOFT.sol";
import {ICommonData, IWithdrawParams} from "tapioca-periph/interfaces/common/ICommonData.sol";
import {UsdoMarketReceiverModule} from "contracts/usdo/modules/UsdoMarketReceiverModule.sol";
import {UsdoOptionReceiverModule} from "contracts/usdo/modules/UsdoOptionReceiverModule.sol";
import {SimpleLeverageExecutor} from "contracts/markets/leverage/SimpleLeverageExecutor.sol";
import {ICommonExternalContracts} from "tapioca-periph/interfaces/common/ICommonData.sol";
import {ILeverageExecutor} from "tapioca-periph/interfaces/bar/ILeverageExecutor.sol";
import {ERC20WithoutStrategy} from "yieldbox/strategies/ERC20WithoutStrategy.sol";
import {ISingularity} from "tapioca-periph/interfaces/bar/ISingularity.sol";
import {Singularity} from "contracts/markets/singularity/Singularity.sol";
import {UsdoMsgCodec} from "contracts/usdo/libraries/UsdoMsgCodec.sol";
import {UsdoReceiver} from "contracts/usdo/modules/UsdoReceiver.sol";
import {IOracle} from "tapioca-periph/oracle/interfaces/IOracle.sol";
import {IPenrose} from "tapioca-periph/interfaces/bar/IPenrose.sol";
import {UsdoHelper} from "contracts/usdo/extensions/UsdoHelper.sol";
import {UsdoSender} from "contracts/usdo/modules/UsdoSender.sol";
import {Cluster} from "tapioca-periph/Cluster/Cluster.sol";
import {YieldBox} from "yieldbox/YieldBox.sol";
import {Penrose} from "contracts/Penrose.sol";

// Tapioca Tests
import {UsdoTestHelper, TestPenroseData, TestSingularityData} from "./UsdoTestHelper.t.sol";
import {TapiocaOptionsBrokerMock} from "./TapiocaOptionsBrokerMock.sol";
import {MagnetarMock} from "./MagnetarMock.sol";
import {SwapperMock} from "./SwapperMock.sol";
import {OracleMock} from "./OracleMock.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import {UsdoMock} from "./UsdoMock.sol";

import "forge-std/Test.sol";

contract UsdoTest is UsdoTestHelper {
    using OptionsBuilder for bytes;
    using OFTMsgCodec for bytes32;
    using OFTMsgCodec for bytes;

    uint32 aEid = 1;
    uint32 bEid = 2;

    Cluster cluster;
    YieldBox yieldBox;
    ERC20Mock tapOFT;
    ERC20Mock weth;

    UsdoMock aUsdo; //collateral
    UsdoMock bUsdo; //asset

    MagnetarMock magnetar;

    UsdoHelper usdoHelper;

    TapiocaOptionsBrokerMock tOB;

    SwapperMock swapper;
    Penrose penrose;
    SimpleLeverageExecutor leverageExecutor;
    Singularity masterContract;
    Singularity singularity;
    OracleMock oracle;

    uint256 aUsdoYieldBoxId;
    uint256 bUsdoYieldBoxId;

    uint256 internal userAPKey = 0x1;
    uint256 internal userBPKey = 0x2;
    address public userA = vm.addr(userAPKey);
    address public userB = vm.addr(userBPKey);
    uint256 public initialBalance = 100 ether;

    /**
     * DEPLOY setup addresses
     */
    address __endpoint;
    uint256 __hostEid = aEid;
    address __owner = address(this);

    uint16 internal constant SEND = 1; // Send LZ message type
    uint16 internal constant PT_APPROVALS = 500; // Use for ERC20Permit approvals
    uint16 internal constant PT_YB_APPROVE_ASSET = 600; // Use for YieldBox 'setApprovalForAsset(true)' operation
    uint16 internal constant PT_YB_APPROVE_ALL = 601; // Use for YieldBox 'setApprovalForAll(true)' operation
    uint16 internal constant PT_MARKET_PERMIT = 602; // Use for market.permitLend() operation
    uint16 internal constant PT_REMOTE_TRANSFER = 700; // Use for transferring tokens from the contract from another chain
    uint16 internal constant PT_MARKET_REMOVE_ASSET = 900; // Use for remove asset from a market available on another chain
    uint16 internal constant PT_YB_SEND_SGL_LEND_OR_REPAY = 901; // Use to YB deposit, lend/repay on a market available on another chain
    uint16 internal constant PT_LEVERAGE_MARKET_UP = 902; // Use for leverage buy on a market available on another chain
    uint16 internal constant PT_TAP_EXERCISE = 903; // Use for exercise options on tOB available on another chain

    /**
     * @dev TOFT global event checks
     */
    event OFTReceived(bytes32, address, uint256, uint256);
    event ComposeReceived(uint16 indexed msgType, bytes32 indexed guid, bytes composeMsg);

    function setUp() public override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);
        vm.label(userA, "userA");
        vm.label(userB, "userB");

        tapOFT = new ERC20Mock("Tapioca OFT", "TAP");
        vm.label(address(tapOFT), "tapOFT");

        weth = new ERC20Mock("Wrapped Ethereum", "WETH");
        vm.label(address(weth), "WETH");

        setUpEndpoints(3, LibraryType.UltraLightNode);

        {
            yieldBox = createYieldBox();
            cluster = createCluster(aEid, __owner);
            magnetar = createMagnetar(address(cluster));

            vm.label(address(endpoints[aEid]), "aEndpoint");
            vm.label(address(endpoints[bEid]), "bEndpoint");
            vm.label(address(yieldBox), "YieldBox");
            vm.label(address(cluster), "Cluster");
            vm.label(address(magnetar), "Magnetar");
        }

        UsdoInitStruct memory aUsdoInitStruct =
            createInitStruct(address(endpoints[aEid]), __owner, address(yieldBox), address(cluster));
        UsdoSender aUsdoSender = new UsdoSender(aUsdoInitStruct);
        UsdoReceiver aUsdoReceiver = new UsdoReceiver(aUsdoInitStruct);
        UsdoMarketReceiverModule aUsdoMarketReceiverModule = new UsdoMarketReceiverModule(aUsdoInitStruct);
        UsdoOptionReceiverModule aUsdoOptionsReceiverModule = new UsdoOptionReceiverModule(aUsdoInitStruct);
        vm.label(address(aUsdoSender), "aUsdoSender");
        vm.label(address(aUsdoReceiver), "aUsdoReceiver");
        vm.label(address(aUsdoMarketReceiverModule), "aUsdoMarketReceiverModule");
        vm.label(address(aUsdoOptionsReceiverModule), "aUsdoOptionsReceiverModule");

        UsdoModulesInitStruct memory aUsdoModulesInitStruct = createModulesInitStruct(
            address(aUsdoSender),
            address(aUsdoReceiver),
            address(aUsdoMarketReceiverModule),
            address(aUsdoOptionsReceiverModule)
        );
        aUsdo = UsdoMock(
            payable(_deployOApp(type(UsdoMock).creationCode, abi.encode(aUsdoInitStruct, aUsdoModulesInitStruct)))
        );
        vm.label(address(aUsdo), "aUsdo");

        UsdoInitStruct memory bUsdoInitStruct =
            createInitStruct(address(endpoints[bEid]), __owner, address(yieldBox), address(cluster));
        UsdoSender bUsdoSender = new UsdoSender(bUsdoInitStruct);
        UsdoReceiver bUsdoReceiver = new UsdoReceiver(bUsdoInitStruct);
        UsdoMarketReceiverModule bUsdoMarketReceiverModule = new UsdoMarketReceiverModule(bUsdoInitStruct);
        UsdoOptionReceiverModule bUsdoOptionsReceiverModule = new UsdoOptionReceiverModule(bUsdoInitStruct);
        vm.label(address(bUsdoSender), "bUsdoSender");
        vm.label(address(bUsdoReceiver), "bUsdoReceiver");
        vm.label(address(bUsdoMarketReceiverModule), "bUsdoMarketReceiverModule");
        vm.label(address(bUsdoOptionsReceiverModule), "bUsdoOptionsReceiverModule");

        UsdoModulesInitStruct memory bUsdoModulesInitStruct = createModulesInitStruct(
            address(bUsdoSender),
            address(bUsdoReceiver),
            address(bUsdoMarketReceiverModule),
            address(bUsdoOptionsReceiverModule)
        );
        bUsdo = UsdoMock(
            payable(_deployOApp(type(UsdoMock).creationCode, abi.encode(bUsdoInitStruct, bUsdoModulesInitStruct)))
        );
        vm.label(address(bUsdo), "bUsdo");

        usdoHelper = new UsdoHelper();
        vm.label(address(usdoHelper), "usdoHelper");

        // config and wire the ofts
        address[] memory ofts = new address[](2);
        ofts[0] = address(aUsdo);
        ofts[1] = address(bUsdo);
        this.wireOApps(ofts);

        // Setup YieldBox assets
        ERC20WithoutStrategy aUsdoStrategy = createYieldBoxEmptyStrategy(address(yieldBox), address(aUsdo));
        ERC20WithoutStrategy bUsdoStrategy = createYieldBoxEmptyStrategy(address(yieldBox), address(bUsdo));

        aUsdoYieldBoxId = registerYieldBoxAsset(address(yieldBox), address(aUsdo), address(aUsdoStrategy)); //we assume this is the asset Id
        bUsdoYieldBoxId = registerYieldBoxAsset(address(yieldBox), address(bUsdo), address(bUsdoStrategy)); //we assume this is the collateral Id

        tOB = new TapiocaOptionsBrokerMock(address(tapOFT));

        swapper = createSwapper(yieldBox);
        leverageExecutor = createLeverageExecutor(address(yieldBox), address(swapper), address(cluster));
        (penrose, masterContract) = createPenrose(
            TestPenroseData(address(yieldBox), address(cluster), address(tapOFT), address(weth), __owner)
        );
        oracle = createOracle();
        singularity = createSingularity(
            penrose,
            TestSingularityData(
                address(penrose),
                IERC20(address(bUsdo)), //asset
                bUsdoYieldBoxId,
                IERC20(address(aUsdo)), //collateral
                aUsdoYieldBoxId,
                IOracle(address(oracle)),
                ILeverageExecutor(address(leverageExecutor))
            ),
            address(masterContract)
        );

        cluster.updateContract(aEid, address(yieldBox), true);
        cluster.updateContract(aEid, address(magnetar), true);
        cluster.updateContract(aEid, address(tOB), true);
        cluster.updateContract(aEid, address(swapper), true);
        cluster.updateContract(aEid, address(penrose), true);
        cluster.updateContract(aEid, address(masterContract), true);
        cluster.updateContract(aEid, address(oracle), true);
        cluster.updateContract(aEid, address(singularity), true);

        cluster.updateContract(bEid, address(yieldBox), true);
        cluster.updateContract(bEid, address(magnetar), true);
        cluster.updateContract(bEid, address(tOB), true);
        cluster.updateContract(bEid, address(swapper), true);
        cluster.updateContract(bEid, address(penrose), true);
        cluster.updateContract(bEid, address(masterContract), true);
        cluster.updateContract(bEid, address(oracle), true);
        cluster.updateContract(bEid, address(singularity), true);
    }

    /**
     * =================
     *      HELPERS
     * =================
     */

    /**
     * @dev Used to bypass stack too deep
     *
     * @param msgType The message type of the lz Compose.
     * @param guid The message GUID.
     * @param composeMsg The source raw OApp compose message. If compose msg is composed with other msgs,
     * the msg should contain only the compose msg at its index and forward. I.E composeMsg[currentIndex:]
     * @param dstEid The destination EID.
     * @param from The address initiating the composition, typically the OApp where the lzReceive was called.
     * @param to The address of the lzCompose receiver.
     * @param srcMsgSender The address of src EID OFT `msg.sender` call initiator .
     * @param extraOptions The options passed in the source OFT call. Only restriction is to have it contain the actual compose option for the index,
     * whether there are other composed calls or not.
     */
    struct LzOFTComposedData {
        uint16 msgType;
        bytes32 guid;
        bytes composeMsg;
        uint32 dstEid;
        address from;
        address to;
        address srcMsgSender;
        bytes extraOptions;
    }
    /**
     * @notice Call lzCompose on the destination OApp.
     *
     * @dev Be sure to verify the message by calling `TestHelper.verifyPackets()`.
     * @dev Will internally verify the emission of the `ComposeReceived` event with
     * the right msgType, GUID and lzReceive composer message.
     *
     * @param _lzOFTComposedData The data to pass to the lzCompose call.
     */

    function __callLzCompose(LzOFTComposedData memory _lzOFTComposedData) internal {
        vm.expectEmit(true, true, true, false);
        emit ComposeReceived(_lzOFTComposedData.msgType, _lzOFTComposedData.guid, _lzOFTComposedData.composeMsg);

        this.lzCompose(
            _lzOFTComposedData.dstEid,
            _lzOFTComposedData.from,
            _lzOFTComposedData.extraOptions,
            _lzOFTComposedData.guid,
            _lzOFTComposedData.to,
            abi.encodePacked(
                OFTMsgCodec.addressToBytes32(_lzOFTComposedData.srcMsgSender), _lzOFTComposedData.composeMsg
            )
        );
    }

    function test_constructor() public {
        assertEq(address(aUsdo.yieldBox()), address(yieldBox));
        assertEq(address(aUsdo.cluster()), address(cluster));
    }

    function test_erc20_permit() public {
        ERC20PermitStruct memory permit_ =
            ERC20PermitStruct({owner: userA, spender: userB, value: 1e18, nonce: 0, deadline: 1 days});

        bytes32 digest_ = aUsdo.getTypedDataHash(permit_);
        ERC20PermitApprovalMsg memory permitApproval_ =
            __getERC20PermitData(permit_, digest_, address(aUsdo), userAPKey);

        aUsdo.permit(
            permit_.owner,
            permit_.spender,
            permit_.value,
            permit_.deadline,
            permitApproval_.v,
            permitApproval_.r,
            permitApproval_.s
        );
        assertEq(aUsdo.allowance(userA, userB), 1e18);
        assertEq(aUsdo.nonces(userA), 1);
    }

    /**
     * ERC20 APPROVALS
     */
    function test_usdo_erc20_approvals() public {
        address userC_ = vm.addr(0x3);

        ERC20PermitApprovalMsg memory permitApprovalB_;
        ERC20PermitApprovalMsg memory permitApprovalC_;
        bytes memory approvalsMsg_;

        {
            ERC20PermitStruct memory approvalUserB_ =
                ERC20PermitStruct({owner: userA, spender: userB, value: 1e18, nonce: 0, deadline: 1 days});
            ERC20PermitStruct memory approvalUserC_ = ERC20PermitStruct({
                owner: userA,
                spender: userC_,
                value: 2e18,
                nonce: 1, // Nonce is 1 because we already called permit() on userB
                deadline: 2 days
            });

            permitApprovalB_ =
                __getERC20PermitData(approvalUserB_, bUsdo.getTypedDataHash(approvalUserB_), address(bUsdo), userAPKey);

            permitApprovalC_ =
                __getERC20PermitData(approvalUserC_, bUsdo.getTypedDataHash(approvalUserC_), address(bUsdo), userAPKey);

            ERC20PermitApprovalMsg[] memory approvals_ = new ERC20PermitApprovalMsg[](2);
            approvals_[0] = permitApprovalB_;
            approvals_[1] = permitApprovalC_;

            approvalsMsg_ = usdoHelper.buildPermitApprovalMsg(approvals_);
        }

        PrepareLzCallReturn memory prepareLzCallReturn_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_APPROVALS,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 1_000_000,
                    value: 0,
                    data: approvalsMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 1_000_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        verifyPackets(uint32(bEid), address(bUsdo));

        vm.expectEmit(true, true, true, false);
        emit IERC20.Approval(userA, userB, 1e18);

        vm.expectEmit(true, true, true, false);
        emit IERC20.Approval(userA, userC_, 1e18);

        __callLzCompose(
            LzOFTComposedData(
                PT_APPROVALS,
                msgReceipt_.guid,
                composeMsg_,
                bEid,
                address(bUsdo), // Compose creator (at lzReceive)
                address(bUsdo), // Compose receiver (at lzCompose)
                address(this),
                oftMsgOptions_
            )
        );

        assertEq(bUsdo.allowance(userA, userB), 1e18);
        assertEq(bUsdo.allowance(userA, userC_), 2e18);
        assertEq(bUsdo.nonces(userA), 2);
    }

    function test_remote_transfer() public {
        // vars
        uint256 tokenAmount_ = 1 ether;
        LZSendParam memory remoteLzSendParam_;
        MessagingFee memory remoteMsgFee_; // Will be used as value for the composed msg

        /**
         * Setup
         */
        {
            deal(address(bUsdo), address(this), tokenAmount_);

            // @dev `remoteMsgFee_` is to be airdropped on dst to pay for the `remoteTransfer` operation (B->A).
            PrepareLzCallReturn memory prepareLzCallReturn1_ = usdoHelper.prepareLzCall( // B->A data
                IUsdo(address(bUsdo)),
                PrepareLzCallData({
                    dstEid: aEid,
                    recipient: OFTMsgCodec.addressToBytes32(address(this)),
                    amountToSendLD: tokenAmount_,
                    minAmountToCreditLD: tokenAmount_,
                    msgType: SEND,
                    composeMsgData: ComposeMsgData({
                        index: 0,
                        gas: 0,
                        value: 0,
                        data: bytes(""),
                        prevData: bytes(""),
                        prevOptionsData: bytes("")
                    }),
                    lzReceiveGas: 500_000,
                    lzReceiveValue: 0
                })
            );
            remoteLzSendParam_ = prepareLzCallReturn1_.lzSendParam;
            remoteMsgFee_ = prepareLzCallReturn1_.msgFee;
        }

        /**
         * Actions
         */
        RemoteTransferMsg memory remoteTransferData =
            RemoteTransferMsg({composeMsg: new bytes(0), owner: address(this), lzSendParam: remoteLzSendParam_});
        bytes memory remoteTransferMsg_ = usdoHelper.buildRemoteTransferMsg(remoteTransferData);

        PrepareLzCallReturn memory prepareLzCallReturn2_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_REMOTE_TRANSFER,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 500_000,
                    value: uint128(remoteMsgFee_.nativeFee), 
                    data: remoteTransferMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 500_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn2_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn2_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn2_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn2_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        {
            verifyPackets(uint32(bEid), address(bUsdo));

            // Initiate approval
            bUsdo.approve(address(bUsdo), tokenAmount_); // Needs to be pre approved on B chain to be able to transfer

            __callLzCompose(
                LzOFTComposedData(
                    PT_REMOTE_TRANSFER,
                    msgReceipt_.guid,
                    composeMsg_,
                    bEid,
                    address(bUsdo), // Compose creator (at lzReceive)
                    address(bUsdo), // Compose receiver (at lzCompose)
                    address(this),
                    oftMsgOptions_
                )
            );
        }

        // Check arrival
        {
            assertEq(aUsdo.balanceOf(address(this)), 0);
            verifyPackets(uint32(aEid), address(aUsdo)); // Verify B->A transfer
            assertEq(aUsdo.balanceOf(address(this)), tokenAmount_);
        }
    }

    function test_exercise_option() public {
        uint256 erc20Amount_ = 1 ether;

        //setup
        {
            deal(address(aUsdo), address(this), erc20Amount_);

            // @dev send TAP to tOB
            deal(address(tapOFT), address(tOB), erc20Amount_);

            // @dev set `paymentTokenAmount` on `tOB`
            tOB.setPaymentTokenAmount(erc20Amount_);
        }

        //useful in case of withdraw after borrow
        LZSendParam memory withdrawLzSendParam_;
        MessagingFee memory withdrawMsgFee_; // Will be used as value for the composed msg

        {
            // @dev `withdrawMsgFee_` is to be airdropped on dst to pay for the send to source operation (B->A).
            PrepareLzCallReturn memory prepareLzCallReturn1_ = usdoHelper.prepareLzCall( // B->A data
                IUsdo(address(bUsdo)),
                PrepareLzCallData({
                    dstEid: aEid,
                    recipient: OFTMsgCodec.addressToBytes32(address(this)),
                    amountToSendLD: erc20Amount_,
                    minAmountToCreditLD: erc20Amount_,
                    msgType: SEND,
                    composeMsgData: ComposeMsgData({
                        index: 0,
                        gas: 0,
                        value: 0,
                        data: bytes(""),
                        prevData: bytes(""),
                        prevOptionsData: bytes("")
                    }),
                    lzReceiveGas: 500_000,
                    lzReceiveValue: 0
                })
            );
            withdrawLzSendParam_ = prepareLzCallReturn1_.lzSendParam;
            withdrawMsgFee_ = prepareLzCallReturn1_.msgFee;
        }

        /**
         * Actions
         */
        uint256 tokenAmountSD = usdoHelper.toSD(erc20Amount_, aUsdo.decimalConversionRate());

        //approve magnetar
        ExerciseOptionsMsg memory exerciseMsg = ExerciseOptionsMsg({
            optionsData: ITapiocaOptionBrokerCrossChain.IExerciseOptionsData({
                from: address(this),
                target: address(tOB),
                paymentTokenAmount: tokenAmountSD,
                oTAPTokenID: 0, // @dev ignored in TapiocaOptionsBrokerMock
                tapAmount: tokenAmountSD
            }),
            withdrawOnOtherChain: false,
            lzSendParams: LZSendParam({
                sendParam: SendParam({
                    dstEid: 0,
                    to: "0x",
                    amountLD: 0,
                    minAmountLD: 0,
                    extraOptions: "0x",
                    composeMsg: "0x",
                    oftCmd: "0x"
                }),
                fee: MessagingFee({nativeFee: 0, lzTokenFee: 0}),
                extraOptions: "0x",
                refundAddress: address(this)
            }),
            composeMsg: "0x"
        });
        bytes memory sendMsg_ = usdoHelper.buildExerciseOptionMsg(exerciseMsg);

        PrepareLzCallReturn memory prepareLzCallReturn2_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: erc20Amount_,
                minAmountToCreditLD: erc20Amount_,
                msgType: PT_TAP_EXERCISE,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 500_000,
                    value: uint128(withdrawMsgFee_.nativeFee),
                    data: sendMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 500_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn2_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn2_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn2_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn2_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        {
            verifyPackets(uint32(bEid), address(bUsdo));

            __callLzCompose(
                LzOFTComposedData(
                    PT_TAP_EXERCISE,
                    msgReceipt_.guid,
                    composeMsg_,
                    bEid,
                    address(bUsdo), // Compose creator (at lzReceive)
                    address(bUsdo), // Compose receiver (at lzCompose)
                    address(this),
                    oftMsgOptions_
                )
            );
        }

        // Check execution
        {
            // @dev TapiocaOptionsBrokerMock uses 90% of msg.options.paymentTokenAmount
            // @dev we check for the rest (10%) if it was returned
            assertEq(bUsdo.balanceOf(address(this)), erc20Amount_ * 1e4 / 1e5);

            assertEq(tapOFT.balanceOf(address(this)), erc20Amount_);
        }
    }

    function test_usdo_yb_permit_all() public {
        bytes memory approvalMsg_;
        {
            ERC20PermitStruct memory approvalUserB_ =
                ERC20PermitStruct({owner: userA, spender: userB, value: 0, nonce: 0, deadline: 1 days});

            bytes32 digest_ = _getYieldBoxPermitAllTypedDataHash(approvalUserB_);
            YieldBoxApproveAllMsg memory permitApproval_ =
                __getYieldBoxPermitAllData(approvalUserB_, address(yieldBox), true, digest_, userAPKey);

            approvalMsg_ = usdoHelper.buildYieldBoxApproveAllMsg(permitApproval_);
        }

        PrepareLzCallReturn memory prepareLzCallReturn_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_YB_APPROVE_ALL,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 1_000_000,
                    value: 0,
                    data: approvalMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 1_000_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn_.lzSendParam;

        assertEq(yieldBox.isApprovedForAll(address(userA), address(userB)), false);

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        verifyPackets(uint32(bEid), address(bUsdo));

        __callLzCompose(
            LzOFTComposedData(
                PT_YB_APPROVE_ALL,
                msgReceipt_.guid,
                composeMsg_,
                bEid,
                address(bUsdo), // Compose creator (at lzReceive)
                address(bUsdo), // Compose receiver (at lzCompose)
                address(this),
                oftMsgOptions_
            )
        );

        assertEq(yieldBox.isApprovedForAll(address(userA), address(userB)), true);
        assertEq(yieldBox.isApprovedForAll(address(userA), address(this)), false);
    }

    function test_usdo_yb_revoke_all() public {
        bytes memory approvalMsg_;
        {
            ERC20PermitStruct memory approvalUserB_ =
                ERC20PermitStruct({owner: userA, spender: userB, value: 0, nonce: 0, deadline: 1 days});

            bytes32 digest_ = _getYieldBoxPermitAllTypedDataHash(approvalUserB_);
            YieldBoxApproveAllMsg memory permitApproval_ =
                __getYieldBoxPermitAllData(approvalUserB_, address(yieldBox), false, digest_, userAPKey);

            approvalMsg_ = usdoHelper.buildYieldBoxApproveAllMsg(permitApproval_);
        }

        PrepareLzCallReturn memory prepareLzCallReturn_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_YB_APPROVE_ALL,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 1_000_000,
                    value: 0,
                    data: approvalMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 1_000_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn_.lzSendParam;

        vm.prank(address(userA));
        yieldBox.setApprovalForAll(address(userB), true);
        assertEq(yieldBox.isApprovedForAll(address(userA), address(userB)), true);

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        verifyPackets(uint32(bEid), address(bUsdo));

        __callLzCompose(
            LzOFTComposedData(
                PT_YB_APPROVE_ALL,
                msgReceipt_.guid,
                composeMsg_,
                bEid,
                address(bUsdo), // Compose creator (at lzReceive)
                address(bUsdo), // Compose receiver (at lzCompose)
                address(this),
                oftMsgOptions_
            )
        );

        assertEq(yieldBox.isApprovedForAll(address(userA), address(userB)), false);
    }

    function test_usdo_yb_permit_asset() public {
        YieldBoxApproveAssetMsg memory permitApprovalB_;
        YieldBoxApproveAssetMsg memory permitApprovalC_;
        bytes memory approvalsMsg_;

        {
            ERC20PermitStruct memory approvalUserB_ =
                ERC20PermitStruct({owner: userA, spender: userB, value: aUsdoYieldBoxId, nonce: 0, deadline: 1 days});
            ERC20PermitStruct memory approvalUserC_ = ERC20PermitStruct({
                owner: userA,
                spender: address(this),
                value: bUsdoYieldBoxId,
                nonce: 1, // Nonce is 1 because we already called permit() on userB
                deadline: 2 days
            });

            permitApprovalB_ = __getYieldBoxPermitAssetData(
                approvalUserB_, address(yieldBox), true, _getYieldBoxPermitAssetTypedDataHash(approvalUserB_), userAPKey
            );

            permitApprovalC_ = __getYieldBoxPermitAssetData(
                approvalUserC_, address(yieldBox), true, _getYieldBoxPermitAssetTypedDataHash(approvalUserC_), userAPKey
            );

            YieldBoxApproveAssetMsg[] memory approvals_ = new YieldBoxApproveAssetMsg[](2);
            approvals_[0] = permitApprovalB_;
            approvals_[1] = permitApprovalC_;

            approvalsMsg_ = usdoHelper.buildYieldBoxApproveAssetMsg(approvals_);
        }

        PrepareLzCallReturn memory prepareLzCallReturn_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_YB_APPROVE_ASSET,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 1_000_000,
                    value: 0,
                    data: approvalsMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 1_000_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn_.lzSendParam;

        assertEq(yieldBox.isApprovedForAsset(address(userA), address(userB), aUsdoYieldBoxId), false);
        assertEq(yieldBox.isApprovedForAsset(address(userA), address(this), bUsdoYieldBoxId), false);

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        verifyPackets(uint32(bEid), address(bUsdo));

        __callLzCompose(
            LzOFTComposedData(
                PT_YB_APPROVE_ASSET,
                msgReceipt_.guid,
                composeMsg_,
                bEid,
                address(bUsdo), // Compose creator (at lzReceive)
                address(bUsdo), // Compose receiver (at lzCompose)
                address(this),
                oftMsgOptions_
            )
        );

        assertEq(yieldBox.isApprovedForAsset(address(userA), address(userB), aUsdoYieldBoxId), true);
        assertEq(yieldBox.isApprovedForAsset(address(userA), address(this), bUsdoYieldBoxId), true);
    }

    function test_usdo_yb_revoke_asset() public {
        YieldBoxApproveAssetMsg memory permitApprovalB_;
        YieldBoxApproveAssetMsg memory permitApprovalC_;
        bytes memory approvalsMsg_;

        {
            ERC20PermitStruct memory approvalUserB_ =
                ERC20PermitStruct({owner: userA, spender: userB, value: aUsdoYieldBoxId, nonce: 0, deadline: 1 days});
            ERC20PermitStruct memory approvalUserC_ = ERC20PermitStruct({
                owner: userA,
                spender: address(this),
                value: bUsdoYieldBoxId,
                nonce: 1, // Nonce is 1 because we already called permit() on userB
                deadline: 2 days
            });

            permitApprovalB_ = __getYieldBoxPermitAssetData(
                approvalUserB_,
                address(yieldBox),
                false,
                _getYieldBoxPermitAssetTypedDataHash(approvalUserB_),
                userAPKey
            );

            permitApprovalC_ = __getYieldBoxPermitAssetData(
                approvalUserC_,
                address(yieldBox),
                false,
                _getYieldBoxPermitAssetTypedDataHash(approvalUserC_),
                userAPKey
            );

            YieldBoxApproveAssetMsg[] memory approvals_ = new YieldBoxApproveAssetMsg[](2);
            approvals_[0] = permitApprovalB_;
            approvals_[1] = permitApprovalC_;

            approvalsMsg_ = usdoHelper.buildYieldBoxApproveAssetMsg(approvals_);
        }

        PrepareLzCallReturn memory prepareLzCallReturn_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_YB_APPROVE_ASSET,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 1_000_000,
                    value: 0,
                    data: approvalsMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 1_000_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn_.lzSendParam;

        vm.prank(address(userA));
        yieldBox.setApprovalForAsset(address(userB), aUsdoYieldBoxId, true);
        vm.prank(address(userA));
        yieldBox.setApprovalForAsset(address(this), bUsdoYieldBoxId, true);
        assertEq(yieldBox.isApprovedForAsset(address(userA), address(userB), aUsdoYieldBoxId), true);
        assertEq(yieldBox.isApprovedForAsset(address(userA), address(this), bUsdoYieldBoxId), true);

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        verifyPackets(uint32(bEid), address(bUsdo));

        __callLzCompose(
            LzOFTComposedData(
                PT_YB_APPROVE_ASSET,
                msgReceipt_.guid,
                composeMsg_,
                bEid,
                address(bUsdo), // Compose creator (at lzReceive)
                address(bUsdo), // Compose receiver (at lzCompose)
                address(this),
                oftMsgOptions_
            )
        );

        assertEq(yieldBox.isApprovedForAsset(address(userA), address(userB), aUsdoYieldBoxId), false);
        assertEq(yieldBox.isApprovedForAsset(address(userA), address(this), bUsdoYieldBoxId), false);
    }

    function test_usdo_market_permit_asset() public {
        bytes memory approvalMsg_;
        {
            // @dev v,r,s will be completed on `__getMarketPermitData`
            MarketPermitActionMsg memory approvalUserB_ = MarketPermitActionMsg({
                target: address(singularity),
                actionType: 1,
                owner: userA,
                spender: userB,
                value: 1e18,
                deadline: 1 days,
                v: 0,
                r: 0,
                s: 0,
                permitAsset: true
            });

            bytes32 digest_ = _getMarketPermitTypedDataHash(true, 1, userA, userB, 1e18, 1 days);
            MarketPermitActionMsg memory permitApproval_ = __getMarketPermitData(approvalUserB_, digest_, userAPKey);

            approvalMsg_ = usdoHelper.buildMarketPermitApprovalMsg(permitApproval_);
        }

        PrepareLzCallReturn memory prepareLzCallReturn_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_MARKET_PERMIT,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 1_000_000,
                    value: 0,
                    data: approvalMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 1_000_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        verifyPackets(uint32(bEid), address(bUsdo));

        __callLzCompose(
            LzOFTComposedData(
                PT_MARKET_PERMIT,
                msgReceipt_.guid,
                composeMsg_,
                bEid,
                address(bUsdo), // Compose creator (at lzReceive)
                address(bUsdo), // Compose receiver (at lzCompose)
                address(this),
                oftMsgOptions_
            )
        );

        assertEq(singularity.allowance(userA, userB), 1e18);
    }

    function test_usdo_market_permit_collateral() public {
        bytes memory approvalMsg_;
        {
            // @dev v,r,s will be completed on `__getMarketPermitData`
            MarketPermitActionMsg memory approvalUserB_ = MarketPermitActionMsg({
                target: address(singularity),
                actionType: 1,
                owner: userA,
                spender: userB,
                value: 1e18,
                deadline: 1 days,
                v: 0,
                r: 0,
                s: 0,
                permitAsset: false
            });

            bytes32 digest_ = _getMarketPermitTypedDataHash(false, 1, userA, userB, 1e18, 1 days);
            MarketPermitActionMsg memory permitApproval_ = __getMarketPermitData(approvalUserB_, digest_, userAPKey);

            approvalMsg_ = usdoHelper.buildMarketPermitApprovalMsg(permitApproval_);
        }

        PrepareLzCallReturn memory prepareLzCallReturn_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_MARKET_PERMIT,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 1_000_000,
                    value: 0,
                    data: approvalMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 1_000_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        verifyPackets(uint32(bEid), address(bUsdo));

        __callLzCompose(
            LzOFTComposedData(
                PT_MARKET_PERMIT,
                msgReceipt_.guid,
                composeMsg_,
                bEid,
                address(bUsdo), // Compose creator (at lzReceive)
                address(bUsdo), // Compose receiver (at lzCompose)
                address(this),
                oftMsgOptions_
            )
        );

        assertEq(singularity.allowanceBorrow(userA, userB), 1e18);
    }

    function test_usdo_lend() public {
        uint256 erc20Amount_ = 1 ether;
        uint256 tokenAmount_ = 0.5 ether;

        deal(address(bUsdo), address(this), erc20Amount_);

        LZSendParam memory withdrawLzSendParam_;
        MessagingFee memory withdrawMsgFee_; // Will be used as value for the composed msg

        {
            // @dev `withdrawMsgFee_` is to be airdropped on dst to pay for the send to source operation (B->A).
            PrepareLzCallReturn memory prepareLzCallReturn1_ = usdoHelper.prepareLzCall( // B->A data
                IUsdo(address(bUsdo)),
                PrepareLzCallData({
                    dstEid: aEid,
                    recipient: OFTMsgCodec.addressToBytes32(address(this)),
                    amountToSendLD: 0,
                    minAmountToCreditLD: 0,
                    msgType: SEND,
                    composeMsgData: ComposeMsgData({
                        index: 0,
                        gas: 0,
                        value: 0,
                        data: bytes(""),
                        prevData: bytes(""),
                        prevOptionsData: bytes("")
                    }),
                    lzReceiveGas: 500_000,
                    lzReceiveValue: 0
                })
            );
            withdrawLzSendParam_ = prepareLzCallReturn1_.lzSendParam;
            withdrawMsgFee_ = prepareLzCallReturn1_.msgFee;
        }

        /**
         * Actions
         */
        bUsdo.approve(address(magnetar), type(uint256).max);
        singularity.approve(address(magnetar), type(uint256).max);
        yieldBox.setApprovalForAll(address(singularity), true);

        uint256 tokenAmountSD = usdoHelper.toSD(tokenAmount_, aUsdo.decimalConversionRate());

        MarketLendOrRepayMsg memory marketMsg = MarketLendOrRepayMsg({
            user: address(this),
            lendParams: ILendOrRepayParams({
                repay: false,
                depositAmount: tokenAmountSD,
                repayAmount: 0,
                marketHelper: address(magnetar),
                market: address(singularity),
                removeCollateral: false,
                removeCollateralAmount: 0,
                lockData: ITapiocaOptionLiquidityProvision.IOptionsLockData({
                    lock: false,
                    target: address(0),
                    lockDuration: 0,
                    amount: 0,
                    fraction: 0
                }),
                participateData: ITapiocaOptionBroker.IOptionsParticipateData({
                    participate: false,
                    target: address(0),
                    tOLPTokenId: 0
                })
            }),
            withdrawParams: IWithdrawParams({
                withdraw: false,
                withdrawLzFeeAmount: 0,
                withdrawOnOtherChain: false,
                withdrawLzChainId: 0,
                withdrawAdapterParams: "0x",
                unwrap: false,
                refundAddress: payable(0),
                zroPaymentAddress: address(0)
            })
        });

        bytes memory marketMsg_ = usdoHelper.buildMarketLendOrRepayMsg(marketMsg);

        PrepareLzCallReturn memory prepareLzCallReturn2_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_YB_SEND_SGL_LEND_OR_REPAY,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 500_000,
                    value: uint128(withdrawMsgFee_.nativeFee),
                    data: marketMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 500_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn2_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn2_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn2_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn2_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        {
            verifyPackets(uint32(bEid), address(bUsdo));

            __callLzCompose(
                LzOFTComposedData(
                    PT_YB_SEND_SGL_LEND_OR_REPAY,
                    msgReceipt_.guid,
                    composeMsg_,
                    bEid,
                    address(bUsdo), // Compose creator (at lzReceive)
                    address(bUsdo), // Compose receiver (at lzCompose)
                    address(this),
                    oftMsgOptions_
                )
            );
        }

        // Check execution
        {
            assertLt(bUsdo.balanceOf(address(this)), erc20Amount_);
        }
    }

    function test_usdo_repay_and_remove_collateral() public {
        uint256 erc20Amount_ = 1 ether;
        uint256 tokenAmount_ = 0.5 ether;

        // setup
        {
            aUsdo.approve(address(singularity), type(uint256).max);
            aUsdo.approve(address(yieldBox), type(uint256).max);
            bUsdo.approve(address(singularity), type(uint256).max);
            bUsdo.approve(address(yieldBox), type(uint256).max);

            deal(address(bUsdo), address(this), erc20Amount_);
            yieldBox.depositAsset(bUsdoYieldBoxId, address(this), address(this), erc20Amount_, 0);

            yieldBox.setApprovalForAll(address(singularity), true);

            uint256 sh = yieldBox.toShare(bUsdoYieldBoxId, erc20Amount_, false);
            singularity.addAsset(address(this), address(this), false, sh);

            deal(address(aUsdo), address(this), erc20Amount_);
            yieldBox.depositAsset(aUsdoYieldBoxId, address(this), address(this), erc20Amount_, 0);
            uint256 collateralShare = yieldBox.toShare(aUsdoYieldBoxId, erc20Amount_, false);
            singularity.addCollateral(address(this), address(this), false, 0, collateralShare);

            assertEq(singularity.userBorrowPart(address(this)), 0);
            singularity.borrow(address(this), address(this), tokenAmount_);
            assertGt(singularity.userBorrowPart(address(this)), 0);

            // deal more to cover repay fees
            deal(address(bUsdo), address(this), erc20Amount_);
            yieldBox.depositAsset(bUsdoYieldBoxId, address(this), address(this), erc20Amount_, 0);
        }

        LZSendParam memory withdrawLzSendParam_;
        MessagingFee memory withdrawMsgFee_; // Will be used as value for the composed msg

        {
            // @dev `withdrawMsgFee_` is to be airdropped on dst to pay for the send to source operation (B->A).
            PrepareLzCallReturn memory prepareLzCallReturn1_ = usdoHelper.prepareLzCall( // B->A data
                IUsdo(address(bUsdo)),
                PrepareLzCallData({
                    dstEid: aEid,
                    recipient: OFTMsgCodec.addressToBytes32(address(this)),
                    amountToSendLD: 0,
                    minAmountToCreditLD: 0,
                    msgType: SEND,
                    composeMsgData: ComposeMsgData({
                        index: 0,
                        gas: 0,
                        value: 0,
                        data: bytes(""),
                        prevData: bytes(""),
                        prevOptionsData: bytes("")
                    }),
                    lzReceiveGas: 500_000,
                    lzReceiveValue: 0
                })
            );
            withdrawLzSendParam_ = prepareLzCallReturn1_.lzSendParam;
            withdrawMsgFee_ = prepareLzCallReturn1_.msgFee;
        }

        /**
         * Actions
         */
        bUsdo.approve(address(magnetar), type(uint256).max);
        singularity.approveBorrow(address(magnetar), type(uint256).max);
        yieldBox.setApprovalForAll(address(singularity), true);

        uint256 userCollateralShareBefore = singularity.userCollateralShare(address(this));

        uint256 tokenAmountSD = usdoHelper.toSD(tokenAmount_, aUsdo.decimalConversionRate());

        MarketLendOrRepayMsg memory marketMsg = MarketLendOrRepayMsg({
            user: address(this),
            lendParams: ILendOrRepayParams({
                repay: true,
                depositAmount: 0,
                repayAmount: tokenAmount_,
                marketHelper: address(magnetar),
                market: address(singularity),
                removeCollateral: true,
                removeCollateralAmount: tokenAmountSD,
                lockData: ITapiocaOptionLiquidityProvision.IOptionsLockData({
                    lock: false,
                    target: address(0),
                    lockDuration: 0,
                    amount: 0,
                    fraction: 0
                }),
                participateData: ITapiocaOptionBroker.IOptionsParticipateData({
                    participate: false,
                    target: address(0),
                    tOLPTokenId: 0
                })
            }),
            withdrawParams: IWithdrawParams({
                withdraw: false,
                withdrawLzFeeAmount: 0,
                withdrawOnOtherChain: false,
                withdrawLzChainId: 0,
                withdrawAdapterParams: "0x",
                unwrap: false,
                refundAddress: payable(0),
                zroPaymentAddress: address(0)
            })
        });

        bytes memory marketMsg_ = usdoHelper.buildMarketLendOrRepayMsg(marketMsg);

        PrepareLzCallReturn memory prepareLzCallReturn2_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_YB_SEND_SGL_LEND_OR_REPAY,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 500_000,
                    value: uint128(withdrawMsgFee_.nativeFee),
                    data: marketMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 500_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn2_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn2_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn2_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn2_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        {
            verifyPackets(uint32(bEid), address(bUsdo));

            __callLzCompose(
                LzOFTComposedData(
                    PT_YB_SEND_SGL_LEND_OR_REPAY,
                    msgReceipt_.guid,
                    composeMsg_,
                    bEid,
                    address(bUsdo), // Compose creator (at lzReceive)
                    address(bUsdo), // Compose receiver (at lzCompose)
                    address(this),
                    oftMsgOptions_
                )
            );
        }

        // Check execution
        {
            assertEq(singularity.userBorrowPart(address(this)), 0);
            assertGt(userCollateralShareBefore, singularity.userCollateralShare(address(this)));
        }
    }

    function test_market_remove_asset() public {
        uint256 erc20Amount_ = 1 ether;

        // setup
        {
            deal(address(bUsdo), address(this), erc20Amount_);
            bUsdo.approve(address(yieldBox), type(uint256).max);
            yieldBox.depositAsset(bUsdoYieldBoxId, address(this), address(this), erc20Amount_, 0);

            yieldBox.setApprovalForAll(address(singularity), true);

            uint256 sh = yieldBox.toShare(bUsdoYieldBoxId, erc20Amount_, false);
            singularity.addAsset(address(this), address(this), false, sh);
        }

        //useful in case of withdraw after borrow
        LZSendParam memory withdrawLzSendParam_;
        MessagingFee memory withdrawMsgFee_; // Will be used as value for the composed msg

        uint256 tokenAmount_ = 0.5 ether;

        {
            // @dev `withdrawMsgFee_` is to be airdropped on dst to pay for the send to source operation (B->A).
            PrepareLzCallReturn memory prepareLzCallReturn1_ = usdoHelper.prepareLzCall( // B->A data
                IUsdo(address(bUsdo)),
                PrepareLzCallData({
                    dstEid: aEid,
                    recipient: OFTMsgCodec.addressToBytes32(address(this)),
                    amountToSendLD: 0,
                    minAmountToCreditLD: 0,
                    msgType: SEND,
                    composeMsgData: ComposeMsgData({
                        index: 0,
                        gas: 0,
                        value: 0,
                        data: bytes(""),
                        prevData: bytes(""),
                        prevOptionsData: bytes("")
                    }),
                    lzReceiveGas: 500_000,
                    lzReceiveValue: 0
                })
            );
            withdrawLzSendParam_ = prepareLzCallReturn1_.lzSendParam;
            withdrawMsgFee_ = prepareLzCallReturn1_.msgFee;
        }

        /**
         * Actions
         */
        uint256 tokenAmountSD = usdoHelper.toSD(tokenAmount_, aUsdo.decimalConversionRate());

        //approve magnetar
        bUsdo.approve(address(magnetar), type(uint256).max);
        singularity.approve(address(magnetar), type(uint256).max);
        MarketRemoveAssetMsg memory marketMsg = MarketRemoveAssetMsg({
            user: address(this),
            externalData: ICommonExternalContracts({
                magnetar: address(magnetar),
                singularity: address(singularity),
                bigBang: address(0)
            }),
            removeAndRepayData: IRemoveAndRepay({
                removeAssetFromSGL: true,
                removeAmount: tokenAmountSD,
                repayAssetOnBB: false,
                repayAmount: 0,
                removeCollateralFromBB: false,
                collateralAmount: 0,
                exitData: ITapiocaOptionBroker.IOptionsExitData({exit: false, target: address(0), oTAPTokenID: 0}),
                unlockData: ITapiocaOptionLiquidityProvision.IOptionsUnlockData({unlock: false, target: address(0), tokenId: 0}),
                assetWithdrawData: IWithdrawParams({
                    withdraw: false,
                    withdrawLzFeeAmount: 0,
                    withdrawOnOtherChain: false,
                    withdrawLzChainId: 0,
                    withdrawAdapterParams: "0x",
                    unwrap: false,
                    refundAddress: payable(0),
                    zroPaymentAddress: address(0)
                }),
                collateralWithdrawData: IWithdrawParams({
                    withdraw: false,
                    withdrawLzFeeAmount: 0,
                    withdrawOnOtherChain: false,
                    withdrawLzChainId: 0,
                    withdrawAdapterParams: "0x",
                    unwrap: false,
                    refundAddress: payable(0),
                    zroPaymentAddress: address(0)
                })
            })
        });
        bytes memory marketMsg_ = usdoHelper.buildMarketRemoveAssetMsg(marketMsg);

        PrepareLzCallReturn memory prepareLzCallReturn2_ = usdoHelper.prepareLzCall(
            IUsdo(address(aUsdo)),
            PrepareLzCallData({
                dstEid: bEid,
                recipient: OFTMsgCodec.addressToBytes32(address(this)),
                amountToSendLD: 0,
                minAmountToCreditLD: 0,
                msgType: PT_MARKET_REMOVE_ASSET,
                composeMsgData: ComposeMsgData({
                    index: 0,
                    gas: 500_000,
                    value: uint128(withdrawMsgFee_.nativeFee),
                    data: marketMsg_,
                    prevData: bytes(""),
                    prevOptionsData: bytes("")
                }),
                lzReceiveGas: 500_000,
                lzReceiveValue: 0
            })
        );
        bytes memory composeMsg_ = prepareLzCallReturn2_.composeMsg;
        bytes memory oftMsgOptions_ = prepareLzCallReturn2_.oftMsgOptions;
        MessagingFee memory msgFee_ = prepareLzCallReturn2_.msgFee;
        LZSendParam memory lzSendParam_ = prepareLzCallReturn2_.lzSendParam;

        (MessagingReceipt memory msgReceipt_,) = aUsdo.sendPacket{value: msgFee_.nativeFee}(lzSendParam_, composeMsg_);

        {
            verifyPackets(uint32(bEid), address(bUsdo));

            __callLzCompose(
                LzOFTComposedData(
                    PT_MARKET_REMOVE_ASSET,
                    msgReceipt_.guid,
                    composeMsg_,
                    bEid,
                    address(bUsdo), // Compose creator (at lzReceive)
                    address(bUsdo), // Compose receiver (at lzCompose)
                    address(this),
                    oftMsgOptions_
                )
            );
        }

        // Check execution
        {
            assertEq(bUsdo.balanceOf(address(this)), 0);
            assertEq(
                yieldBox.toAmount(bUsdoYieldBoxId, yieldBox.balanceOf(address(this), bUsdoYieldBoxId), false),
                tokenAmount_
            );
        }
    }

    function _getMarketPermitTypedDataHash(
        bool permitAsset,
        uint16 actionType_,
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_
    ) private view returns (bytes32) {
        bytes32 permitTypeHash_ = permitAsset
            ? keccak256(
                "Permit(uint16 actionType,address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
            )
            : keccak256(
                "PermitBorrow(uint16 actionType,address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
            );

        uint256 nonce = singularity.nonces(owner_);
        bytes32 structHash_ =
            keccak256(abi.encode(permitTypeHash_, actionType_, owner_, spender_, value_, nonce++, deadline_));

        return keccak256(abi.encodePacked("\x19\x01", singularity.DOMAIN_SEPARATOR(), structHash_));
    }

    function _getYieldBoxPermitAllTypedDataHash(ERC20PermitStruct memory _permitData) private view returns (bytes32) {
        bytes32 permitTypeHash_ = keccak256("PermitAll(address owner,address spender,uint256 nonce,uint256 deadline)");

        bytes32 structHash_ = keccak256(
            abi.encode(permitTypeHash_, _permitData.owner, _permitData.spender, _permitData.nonce, _permitData.deadline)
        );

        return keccak256(abi.encodePacked("\x19\x01", _getYieldBoxDomainSeparator(), structHash_));
    }

    function _getYieldBoxPermitAssetTypedDataHash(ERC20PermitStruct memory _permitData)
        private
        view
        returns (bytes32)
    {
        bytes32 permitTypeHash_ =
            keccak256("Permit(address owner,address spender,uint256 assetId,uint256 nonce,uint256 deadline)");

        bytes32 structHash_ = keccak256(
            abi.encode(
                permitTypeHash_,
                _permitData.owner,
                _permitData.spender,
                _permitData.value, // @dev this is the assetId
                _permitData.nonce,
                _permitData.deadline
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", _getYieldBoxDomainSeparator(), structHash_));
    }

    function _getYieldBoxDomainSeparator() private view returns (bytes32) {
        bytes32 typeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 hashedName = keccak256(bytes("YieldBox"));
        bytes32 hashedVersion = keccak256(bytes("1"));
        bytes32 domainSeparator =
            keccak256(abi.encode(typeHash, hashedName, hashedVersion, block.chainid, address(yieldBox)));
        return domainSeparator;
    }
}
