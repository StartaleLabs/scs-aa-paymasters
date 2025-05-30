// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "../../TestBase.sol";
import {StartaleTokenPaymaster} from "../../../../src/token/startale/StartaleTokenPaymaster.sol";
import {IStartaleTokenPaymaster} from "../../../../src/interfaces/IStartaleTokenPaymaster.sol";
import {IStartaleTokenPaymasterEventsAndErrors} from
    "../../../../src/interfaces/IStartaleTokenPaymasterEventsAndErrors.sol";
import "@account-abstraction/contracts/interfaces/IStakeManager.sol";
import {MultiSigners} from "../../../../src/lib/MultiSigners.sol";
import {TestCounter} from "../../TestCounter.sol";
import {MockToken} from "../../mock/MockToken.sol";
import {MockOracle} from "../../mock/MockOracle.sol";
import {IOracle} from "../../../../src/interfaces/IOracle.sol";
import {PriceOracleHelper} from "../../../../src/token/startale/PriceOracleHelper.sol";

contract TestTokenPaymaster is TestBase {
    uint256 public constant WITHDRAWAL_DELAY = 3600;
    uint256 public constant MIN_DEPOSIT = 1e15;
    uint256 public constant TOKEN_PM_UNACCOUNTED_GAS = 50e3;
    uint48 public constant MAX_ORACLE_ROUND_AGE = 1000;

    StartaleTokenPaymaster public tokenPaymaster;
    MockOracle public nativeAssetToUsdOracle;
    MockOracle public tokenToUsdOracle;
    TestCounter public testCounter;
    MockToken public testToken;

    function setUp() public {
        setupPaymasterTestEnvironment();
        // Deploy Sponsorship Paymaster
        address[] memory signers = new address[](2);
        signers[0] = PAYMASTER_SIGNER_A.addr;
        signers[1] = PAYMASTER_SIGNER_B.addr;

        nativeAssetToUsdOracle = new MockOracle(100_000_000, 8); // Oracle with 8 decimals for ETH // ETH/USD
        nativeAssetToUsdOracle.setUpdatedAtDelay(500);
        // let's say this is WETH
        tokenToUsdOracle = new MockOracle(100_000_000, 8); // Oracle with 8 decimals for ERC20 token // TKN/USD
        tokenToUsdOracle.setUpdatedAtDelay(500);
        testToken = new MockToken("Test Token", "TKN");

        tokenPaymaster = new StartaleTokenPaymaster({
            _owner: PAYMASTER_OWNER.addr,
            _entryPoint: address(ENTRYPOINT),
            _signers: signers,
            _tokenFeesTreasury: PAYMASTER_FEE_COLLECTOR.addr,
            _unaccountedGas: TOKEN_PM_UNACCOUNTED_GAS,
            _nativeAssetToUsdOracle: address(nativeAssetToUsdOracle),
            _sequencerUptimeOracle: address(0),
            _nativeAssetMaxOracleRoundAge: MAX_ORACLE_ROUND_AGE,
            _nativeAssetDecimals: 18,
            _independentTokens: _toSingletonArray(address(testToken)),
            _feeMarkupsForIndependentTokens: _toSingletonArray(1e6),
            _tokenOracleConfigs: _toSingletonArray(
                IOracleHelper.TokenOracleConfig({tokenOracle: IOracle(address(tokenToUsdOracle)), maxOracleRoundAge: 1000})
            )
        });
    }

    function test_Deploy_STPM() external {
        address[] memory signers = new address[](2);
        signers[0] = PAYMASTER_SIGNER_A.addr;
        signers[1] = PAYMASTER_SIGNER_B.addr;
        // Deploy the token paymaster
        StartaleTokenPaymaster testArtifact = new StartaleTokenPaymaster(
            PAYMASTER_OWNER.addr,
            ENTRYPOINT_ADDRESS,
            signers,
            PAYMASTER_FEE_COLLECTOR.addr,
            TOKEN_PM_UNACCOUNTED_GAS, // unaccounted gas
            address(nativeAssetToUsdOracle),
            address(0),
            MAX_ORACLE_ROUND_AGE,
            18, // native token decimals
            _toSingletonArray(address(testToken)),
            _toSingletonArray(1e6),
            _toSingletonArray(
                IOracleHelper.TokenOracleConfig({
                    tokenOracle: IOracle(address(tokenToUsdOracle)),
                    maxOracleRoundAge: MAX_ORACLE_ROUND_AGE
                })
            )
        );

        assertEq(testArtifact.owner(), PAYMASTER_OWNER.addr);
        assertEq(address(testArtifact.entryPoint()), ENTRYPOINT_ADDRESS);
        assertEq(testArtifact.isSigner(PAYMASTER_SIGNER_A.addr), true);
        assertEq(testArtifact.isSigner(PAYMASTER_SIGNER_B.addr), true);
        assertEq(address(testArtifact.nativeAssetToUsdOracle()), address(nativeAssetToUsdOracle));
        assertEq(testArtifact.unaccountedGas(), TOKEN_PM_UNACCOUNTED_GAS);
    }

    function test_Deposit() external prankModifier(PAYMASTER_OWNER.addr) {
        uint256 depositAmount = 10 ether;
        assertEq(tokenPaymaster.getDeposit(), 0);

        tokenPaymaster.deposit{value: depositAmount}();
        assertEq(tokenPaymaster.getDeposit(), depositAmount);
    }

    function test_WithdrawTo() external prankModifier(PAYMASTER_OWNER.addr) {
        uint256 depositAmount = 10 ether;
        tokenPaymaster.deposit{value: depositAmount}();
        uint256 initialBalance = BOB_ADDRESS.balance;

        // Withdraw ETH to BOB_ADDRESS and verify the balance changes
        tokenPaymaster.withdrawTo(payable(BOB_ADDRESS), depositAmount);

        assertEq(BOB_ADDRESS.balance, initialBalance + depositAmount);
        assertEq(tokenPaymaster.getDeposit(), 0);
    }

    function test_WithdrawERC20() external prankModifier(PAYMASTER_OWNER.addr) {
        uint256 mintAmount = 10 * (10 ** testToken.decimals());
        testToken.mint(address(tokenPaymaster), mintAmount);

        // Ensure that the paymaster has the tokens
        assertEq(testToken.balanceOf(address(tokenPaymaster)), mintAmount);
        assertEq(testToken.balanceOf(ALICE_ADDRESS), 0);

        // Expect the `TokensWithdrawn` event to be emitted with the correct values
        vm.expectEmit(true, true, true, true, address(tokenPaymaster));
        emit IStartaleTokenPaymasterEventsAndErrors.TokensWithdrawn(
            address(testToken), ALICE_ADDRESS, PAYMASTER_OWNER.addr, mintAmount
        );

        // Withdraw tokens and validate balances
        tokenPaymaster.withdrawERC20(testToken, ALICE_ADDRESS, mintAmount);

        assertEq(testToken.balanceOf(address(tokenPaymaster)), 0);
        assertEq(testToken.balanceOf(ALICE_ADDRESS), mintAmount);
    }

    function test_Success_TokenPaymaster_ExternalMode_WithoutPremium() external {
        tokenPaymaster.deposit{value: 10 ether}();
        testToken.mint(address(ALICE_ACCOUNT), 100_000 * (10 ** testToken.decimals()));

        vm.startPrank(PAYMASTER_OWNER.addr);
        // Note: unaccounted gas for external mode is different as there is no call to the oracles.
        tokenPaymaster.setUnaccountedGas(20_000);
        vm.stopPrank();

        // Warm up the ERC20 balance slot for tokenFeeTreasury by making some tokens held initially
        testToken.mint(PAYMASTER_FEE_COLLECTOR.addr, 100_000 * (10 ** testToken.decimals()));

        uint256 initialBundlerBalance = BUNDLER.addr.balance;
        uint256 initialPaymasterEpBalance = tokenPaymaster.getDeposit();
        uint256 initialUserTokenBalance = testToken.balanceOf(address(ALICE_ACCOUNT));
        uint256 initialPaymasterTokenBalance = testToken.balanceOf(address(tokenPaymaster));
        uint256 initialTokenFeeTreasuryBalance = testToken.balanceOf(PAYMASTER_FEE_COLLECTOR.addr);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);

        uint48 validUntil = uint48(block.timestamp + 1 days);
        uint48 validAfter = uint48(block.timestamp);
        uint256 tokenPrice = 1e18; // Assume 1 token = 1 native token = 1 USD ?
        uint32 externalFeeMarkup = 1e6; // no premium

        // Good part of not doing pre-charge and only charging in postOp is we can give approval during the execution phase.
        // So we build a userOp with approve calldata.
        bytes memory userOpCalldata = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(testToken),
            0,
            abi.encodeWithSelector(testToken.approve.selector, address(tokenPaymaster), 1000 * 1e18)
        );

        // Generate and sign the token paymaster data
        (PackedUserOperation memory userOp, bytes32 userOpHash) = createUserOpWithTokenPaymasterAndExternalMode(
            ALICE, tokenPaymaster, address(testToken), 1e18, externalFeeMarkup, 100_000, userOpCalldata
        );

        ops[0] = userOp;

        vm.expectEmit(true, true, false, false, address(tokenPaymaster));
        emit IStartaleTokenPaymasterEventsAndErrors.PaidGasInTokens(
            address(ALICE_ACCOUNT), address(testToken), 0, 1e6, 0
        );

        // Execute the operation
        startPrank(BUNDLER.addr);
        uint256 gasValue = gasleft();
        ENTRYPOINT.handleOps(ops, payable(BUNDLER.addr));
        gasValue = gasValue - gasleft();
        stopPrank();

        uint256 gasPaidBySAInERC20 = initialUserTokenBalance - testToken.balanceOf(address(ALICE_ACCOUNT));

        uint256 gasCollectedInERC20ByFeeCollector =
            testToken.balanceOf(PAYMASTER_FEE_COLLECTOR.addr) - initialTokenFeeTreasuryBalance;

        // // What user paid = received by paymaster fee collector
        // unless ofcourse there is same token transfer in calldata
        assertEq(gasPaidBySAInERC20, gasCollectedInERC20ByFeeCollector);

        // calculateAndAssertAdjustmentsForTokenPaymaster...
        uint256 totalGasFeePaid = BUNDLER.addr.balance - initialBundlerBalance;

        // Assert that what paymaster paid is the same as what the bundler received
        assertEq(totalGasFeePaid, initialPaymasterEpBalance - tokenPaymaster.getDeposit());

        uint256 gasPaidBySAInNativeTokens = gasPaidBySAInERC20 * 1e18 / tokenPrice;

        // Assert we never undercharge
        assertGe(gasPaidBySAInNativeTokens, BUNDLER.addr.balance - initialBundlerBalance);

        // Since there is no premium, the paymaster should have received the same amount of tokens as it paid for
        // Ensure that max 2% difference between total gas paid + the adjustment premium(if any) and gas paid by dapp (from
        // paymaster)
        assertApproxEqRel(totalGasFeePaid, gasPaidBySAInNativeTokens, 0.02e18);
    }

    function test_ParsePaymasterAndDataForExternalMode() external view {
        PackedUserOperation memory userOp = buildUserOpWithCalldata(ALICE, "", 0, 0);

        TokenPaymasterDataExternalMode memory pmData = TokenPaymasterDataExternalMode({
            validationGasLimit: uint128(100_000),
            postOpGasLimit: uint128(100_000),
            mode: IStartaleTokenPaymaster.PaymasterMode.EXTERNAL,
            validUntil: uint48(block.timestamp + 1 days),
            validAfter: uint48(block.timestamp),
            tokenAddress: address(testToken),
            exchangeRate: 1e18,
            appliedFeeMarkup: 1e6
        });

        bytes memory pmSignature;

        (userOp.paymasterAndData, pmSignature) =
            generateAndSignTokenPaymasterDataExternalMode(userOp, PAYMASTER_SIGNER_A, tokenPaymaster, pmData);

        (
            uint48 parsedValidUntil,
            uint48 parsedValidAfter,
            address parsedTokenAddress,
            uint256 parsedExchangeRate,
            uint48 parsedAppliedFeeMarkup,
            uint128 parsedPaymasterValidationGasLimit,
            uint128 parsedPaymasterPostOpGasLimit,
            bytes memory parsedSignature
        ) = tokenPaymaster.parsePaymasterAndDataForExternalMode(userOp.paymasterAndData);

        assertEq(pmData.validUntil, parsedValidUntil);
        assertEq(pmData.validAfter, parsedValidAfter);
        assertEq(pmData.tokenAddress, parsedTokenAddress);
        assertEq(pmData.exchangeRate, parsedExchangeRate);
        assertEq(pmData.appliedFeeMarkup, parsedAppliedFeeMarkup);
        assertEq(pmData.validationGasLimit, parsedPaymasterValidationGasLimit);
        assertEq(pmData.postOpGasLimit, parsedPaymasterPostOpGasLimit);
        assertEq(parsedSignature, pmSignature);
        assertEq(parsedSignature.length, userOp.signature.length);
    }

    function test_Success_TokenPaymaster_ExternalMode_WithPremium() external {
        tokenPaymaster.deposit{value: 10 ether}();
        testToken.mint(address(ALICE_ACCOUNT), 100_000 * (10 ** testToken.decimals()));

        vm.startPrank(PAYMASTER_OWNER.addr);
        // Note: unaccounted gas for external mode is different as there is no call to the oracles.
        tokenPaymaster.setUnaccountedGas(20_000);
        vm.stopPrank();

        // Warm up the ERC20 balance slot for tokenFeeTreasury by making some tokens held initially
        testToken.mint(PAYMASTER_FEE_COLLECTOR.addr, 100_000 * (10 ** testToken.decimals()));

        uint256 initialBundlerBalance = BUNDLER.addr.balance;
        uint256 initialPaymasterEpBalance = tokenPaymaster.getDeposit();
        uint256 initialUserTokenBalance = testToken.balanceOf(address(ALICE_ACCOUNT));
        // uint256 initialPaymasterTokenBalance = testToken.balanceOf(address(tokenPaymaster));
        uint256 initialTokenFeeTreasuryBalance = testToken.balanceOf(PAYMASTER_FEE_COLLECTOR.addr);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);

        // uint48 validUntil = uint48(block.timestamp + 1 days);
        // uint48 validAfter = uint48(block.timestamp);
        uint256 tokenPrice = 1e18; // Assume 1 token = 1 native token = 1 USD ?
        uint32 externalFeeMarkup = 1.2e6; // premium

        // Good part of not doing pre-charge and only charging in postOp is we can give approval during the execution phase.
        // So we build a userOp with approve calldata.
        bytes memory userOpCalldata = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(testToken),
            0,
            abi.encodeWithSelector(testToken.approve.selector, address(tokenPaymaster), 1000 * 1e18)
        );

        // Generate and sign the token paymaster data
        (PackedUserOperation memory userOp, bytes32 userOpHash) = createUserOpWithTokenPaymasterAndExternalMode(
            ALICE, tokenPaymaster, address(testToken), 1e18, externalFeeMarkup, 100_000, userOpCalldata
        );

        ops[0] = userOp;

        vm.expectEmit(true, true, false, false, address(tokenPaymaster));
        emit IStartaleTokenPaymasterEventsAndErrors.PaidGasInTokens(
            address(ALICE_ACCOUNT), address(testToken), 0, 1e6, 0
        );

        // Execute the operation
        startPrank(BUNDLER.addr);
        uint256 gasValue = gasleft();
        ENTRYPOINT.handleOps(ops, payable(BUNDLER.addr));
        gasValue = gasValue - gasleft();
        stopPrank();

        uint256 gasPaidBySAInERC20 = initialUserTokenBalance - testToken.balanceOf(address(ALICE_ACCOUNT));

        uint256 gasCollectedInERC20ByFeeCollector =
            testToken.balanceOf(PAYMASTER_FEE_COLLECTOR.addr) - initialTokenFeeTreasuryBalance;

        // // What user paid = received by paymaster fee collector
        // unless ofcourse there is same token transfer in calldata
        assertEq(gasPaidBySAInERC20, gasCollectedInERC20ByFeeCollector);

        // calculateAndAssertAdjustmentsForTokenPaymaster...
        uint256 totalGasFeePaid = BUNDLER.addr.balance - initialBundlerBalance;

        // Assert that what paymaster paid is the same as what the bundler received
        assertEq(totalGasFeePaid, initialPaymasterEpBalance - tokenPaymaster.getDeposit());

        uint256 gasPaidBySAInNativeTokens = gasPaidBySAInERC20 * 1e18 / tokenPrice;

        // Assert we never undercharge
        assertGe(gasPaidBySAInNativeTokens, BUNDLER.addr.balance - initialBundlerBalance);

        // Ensure that max 2% difference between total gas paid + the adjustment premium and gas paid by dapp (from
        // paymaster)
        assertApproxEqRel(totalGasFeePaid * externalFeeMarkup / 1e6, gasPaidBySAInNativeTokens, 0.02e18);
    }

    function test_Success_TokenPaymaster_IndependentMode_WithoutPremium() external {
        vm.warp(1742296776);
        tokenPaymaster.deposit{value: 10 ether}();
        testToken.mint(address(ALICE_ACCOUNT), 100_000 * (10 ** testToken.decimals()));

        vm.startPrank(PAYMASTER_OWNER.addr);
        tokenPaymaster.setUnaccountedGas(20_000);
        vm.stopPrank();

        // Warm up the ERC20 balance slot for tokenFeeTreasury by making some tokens held initially
        testToken.mint(PAYMASTER_FEE_COLLECTOR.addr, 100_000 * (10 ** testToken.decimals()));

        uint256 initialBundlerBalance = BUNDLER.addr.balance;
        uint256 initialPaymasterEpBalance = tokenPaymaster.getDeposit();
        uint256 initialUserTokenBalance = testToken.balanceOf(address(ALICE_ACCOUNT));
        // uint256 initialPaymasterTokenBalance = testToken.balanceOf(address(tokenPaymaster));
        uint256 initialTokenFeeTreasuryBalance = testToken.balanceOf(PAYMASTER_FEE_COLLECTOR.addr);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);

        // Good part of not doing pre-charge and only charging in postOp is we can give approval during the execution phase.
        // So we build a userOp with approve calldata.
        bytes memory userOpCalldata = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(testToken),
            0,
            abi.encodeWithSelector(testToken.approve.selector, address(tokenPaymaster), 1000 * 1e18)
        );

        // Generate and sign the token paymaster data
        (PackedUserOperation memory userOp, bytes32 userOpHash) = createUserOpWithTokenPaymasterAndIndependentMode(
            ALICE, tokenPaymaster, address(testToken), 100_000, userOpCalldata
        );

        ops[0] = userOp;

        vm.expectEmit(true, true, false, false, address(tokenPaymaster));
        emit IStartaleTokenPaymasterEventsAndErrors.PaidGasInTokens(
            address(ALICE_ACCOUNT), address(testToken), 0, 1e6, 0
        );

        // Execute the operation
        startPrank(BUNDLER.addr);
        uint256 gasValue = gasleft();
        ENTRYPOINT.handleOps(ops, payable(BUNDLER.addr));
        gasValue = gasValue - gasleft();
        stopPrank();

        (uint256 exchangeRate, uint256 exchangeRateValidUntil, uint256 exchangeRateValidAfter) =
            tokenPaymaster.getExchangeRate(address(testToken));

        uint256 gasPaidBySAInERC20 = initialUserTokenBalance - testToken.balanceOf(address(ALICE_ACCOUNT));

        uint256 gasCollectedInERC20ByFeeCollector =
            testToken.balanceOf(PAYMASTER_FEE_COLLECTOR.addr) - initialTokenFeeTreasuryBalance;

        // // What user paid = received by paymaster fee collector
        // unless ofcourse there is same token transfer in calldata
        assertEq(gasPaidBySAInERC20, gasCollectedInERC20ByFeeCollector);

        // calculateAndAssertAdjustmentsForTokenPaymaster...
        uint256 totalGasFeePaid = BUNDLER.addr.balance - initialBundlerBalance;

        // Assert that what paymaster paid is the same as what the bundler received
        assertEq(totalGasFeePaid, initialPaymasterEpBalance - tokenPaymaster.getDeposit());

        uint256 gasPaidBySAInNativeTokens = gasPaidBySAInERC20 * 1e18 / exchangeRate;

        // Assert we never undercharge
        assertGe(gasPaidBySAInNativeTokens, BUNDLER.addr.balance - initialBundlerBalance);

        // Since there is no premium, the paymaster should have received the same amount of tokens as it paid for
        // Ensure that max 2% difference between total gas paid + the adjustment premium and gas paid by dapp (from
        // paymaster)
        assertApproxEqRel(totalGasFeePaid, gasPaidBySAInNativeTokens, 0.02e18);
    }

    function test_Success_TokenPaymaster_IndependentMode_WithPremium() external {
        vm.warp(1742296776);
        tokenPaymaster.deposit{value: 10 ether}();
        testToken.mint(address(ALICE_ACCOUNT), 100_000 * (10 ** testToken.decimals()));

        vm.startPrank(PAYMASTER_OWNER.addr);
        tokenPaymaster.setUnaccountedGas(20_000);
        tokenPaymaster.updateTokenFeeMarkup(address(testToken), 1.2e6);
        vm.stopPrank();

        // Warm up the ERC20 balance slot for tokenFeeTreasury by making some tokens held initially
        testToken.mint(PAYMASTER_FEE_COLLECTOR.addr, 100_000 * (10 ** testToken.decimals()));

        uint256 initialBundlerBalance = BUNDLER.addr.balance;
        uint256 initialPaymasterEpBalance = tokenPaymaster.getDeposit();
        uint256 initialUserTokenBalance = testToken.balanceOf(address(ALICE_ACCOUNT));
        // uint256 initialPaymasterTokenBalance = testToken.balanceOf(address(tokenPaymaster));
        uint256 initialTokenFeeTreasuryBalance = testToken.balanceOf(PAYMASTER_FEE_COLLECTOR.addr);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);

        // Good part of not doing pre-charge and only charging in postOp is we can give approval during the execution phase.
        // So we build a userOp with approve calldata.
        bytes memory userOpCalldata = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(testToken),
            0,
            abi.encodeWithSelector(testToken.approve.selector, address(tokenPaymaster), 1000 * 1e18)
        );

        // Generate and sign the token paymaster data
        (PackedUserOperation memory userOp, bytes32 userOpHash) = createUserOpWithTokenPaymasterAndIndependentMode(
            ALICE, tokenPaymaster, address(testToken), 100_000, userOpCalldata
        );

        ops[0] = userOp;

        vm.expectEmit(true, true, false, false, address(tokenPaymaster));
        emit IStartaleTokenPaymasterEventsAndErrors.PaidGasInTokens(
            address(ALICE_ACCOUNT), address(testToken), 0, 1e6, 0
        );

        // Execute the operation
        startPrank(BUNDLER.addr);
        uint256 gasValue = gasleft();
        ENTRYPOINT.handleOps(ops, payable(BUNDLER.addr));
        gasValue = gasValue - gasleft();
        stopPrank();

        (uint256 exchangeRate, uint256 exchangeRateValidUntil, uint256 exchangeRateValidAfter) =
            tokenPaymaster.getExchangeRate(address(testToken));

        uint256 gasPaidBySAInERC20 = initialUserTokenBalance - testToken.balanceOf(address(ALICE_ACCOUNT));

        uint256 gasCollectedInERC20ByFeeCollector =
            testToken.balanceOf(PAYMASTER_FEE_COLLECTOR.addr) - initialTokenFeeTreasuryBalance;

        // // What user paid = received by paymaster fee collector
        // unless ofcourse there is same token transfer in calldata
        assertEq(gasPaidBySAInERC20, gasCollectedInERC20ByFeeCollector);

        // calculateAndAssertAdjustmentsForTokenPaymaster...
        uint256 totalGasFeePaid = BUNDLER.addr.balance - initialBundlerBalance;

        // Assert that what paymaster paid is the same as what the bundler received
        assertEq(totalGasFeePaid, initialPaymasterEpBalance - tokenPaymaster.getDeposit());

        uint256 gasPaidBySAInNativeTokens = gasPaidBySAInERC20 * 1e18 / exchangeRate;

        uint256 gasCollectedInERC20ByFeeCollectorInNativeTokens =
            gasCollectedInERC20ByFeeCollector * 1e18 / exchangeRate;

        // Assert we never undercharge
        assertGe(gasPaidBySAInNativeTokens, BUNDLER.addr.balance - initialBundlerBalance);

        // Ensure that max 2% difference between total gas paid + the adjustment premium and gas paid by dapp (from
        // paymaster)
        assertApproxEqRel(totalGasFeePaid * 1.2e6 / 1e6, gasPaidBySAInNativeTokens, 0.02e18);
    }

    function test_Revert_PostOp_If_PriceExpired() external {
        tokenToUsdOracle.setUpdatedAtDelay(10000);

        vm.startPrank(PAYMASTER_OWNER.addr);
        tokenPaymaster.updateTokenOracleConfig(
            address(testToken),
            IOracleHelper.TokenOracleConfig({tokenOracle: IOracle(address(tokenToUsdOracle)), maxOracleRoundAge: 1000})
        );
        vm.stopPrank();

        vm.warp(1742296776);
        tokenPaymaster.deposit{value: 10 ether}();
        testToken.mint(address(ALICE_ACCOUNT), 100_000 * (10 ** testToken.decimals()));

        vm.startPrank(PAYMASTER_OWNER.addr);
        tokenPaymaster.setUnaccountedGas(40_000);
        vm.stopPrank();

        // Warm up the ERC20 balance slot for tokenFeeTreasury by making some tokens held initially
        testToken.mint(PAYMASTER_FEE_COLLECTOR.addr, 100_000 * (10 ** testToken.decimals()));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);

        // Good part of not doing pre-charge and only charging in postOp is we can give approval during the execution phase.
        // So we build a userOp with approve calldata.
        bytes memory userOpCalldata = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(testToken),
            0,
            abi.encodeWithSelector(testToken.approve.selector, address(tokenPaymaster), 1000 * 1e18)
        );

        // Generate and sign the token paymaster data
        (PackedUserOperation memory userOp, bytes32 userOpHash) = createUserOpWithTokenPaymasterAndIndependentMode(
            ALICE, tokenPaymaster, address(testToken), 100_000, userOpCalldata
        );

        ops[0] = userOp;

        // Execute the operation
        startPrank(BUNDLER.addr);
        uint256 gasValue = gasleft();

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA32 paymaster expired or not due"));

        ENTRYPOINT.handleOps(ops, payable(BUNDLER.addr));
        gasValue = gasValue - gasleft();
        stopPrank();
    }

    function test_RevertIf_InvalidTokenAddress_Independent_Mode() public {
        MockToken invalidToken = new MockToken("Unsupported", "RANDERC20");
        vm.warp(1742296776);
        tokenPaymaster.deposit{value: 10 ether}();
        invalidToken.mint(address(ALICE_ACCOUNT), 100_000 * (10 ** testToken.decimals()));

        vm.startPrank(PAYMASTER_OWNER.addr);
        tokenPaymaster.setUnaccountedGas(40_000);
        vm.stopPrank();

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);

        bytes memory userOpCalldata = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(invalidToken),
            0,
            abi.encodeWithSelector(invalidToken.approve.selector, address(tokenPaymaster), 1000 * 1e18)
        );

        // Generate and sign the token paymaster data
        (PackedUserOperation memory userOp, bytes32 userOpHash) = createUserOpWithTokenPaymasterAndIndependentMode(
            ALICE, tokenPaymaster, address(invalidToken), 100_000, userOpCalldata
        );

        ops[0] = userOp;

        startPrank(BUNDLER.addr);
        uint256 gasValue = gasleft();

        bytes memory expectedRevertReason = abi.encodeWithSelector(
            IEntryPoint.FailedOpWithRevert.selector,
            0,
            "AA33 reverted",
            abi.encodeWithSelector(
                IStartaleTokenPaymasterEventsAndErrors.TokenNotSupported.selector, address(invalidToken)
            )
        );
        vm.expectRevert(expectedRevertReason);

        ENTRYPOINT.handleOps(ops, payable(BUNDLER.addr));
        gasValue = gasValue - gasleft();
        stopPrank();
    }

    function test_RevertIf_UserDoesNotHaveEnoughBalance_Any_Mode() public {
        vm.warp(1742296776);
        tokenPaymaster.deposit{value: 10 ether}();
        // Let's not give ALICE any tokens this time.
        // This would be a problem in postOp.

        vm.startPrank(PAYMASTER_OWNER.addr);
        tokenPaymaster.setUnaccountedGas(40_000);
        vm.stopPrank();

        // Warm up the ERC20 balance slot for tokenFeeTreasury by making some tokens held initially
        testToken.mint(PAYMASTER_FEE_COLLECTOR.addr, 100_000 * (10 ** testToken.decimals()));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);

        // Good part of not doing pre-charge and only charging in postOp is we can give approval during the execution phase.
        // So we build a userOp with approve calldata.
        bytes memory userOpCalldata = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(testToken),
            0,
            abi.encodeWithSelector(testToken.approve.selector, address(tokenPaymaster), 1000 * 1e18)
        );

        // Generate and sign the token paymaster data
        (PackedUserOperation memory userOp, bytes32 userOpHash) = createUserOpWithTokenPaymasterAndIndependentMode(
            ALICE, tokenPaymaster, address(testToken), 100_000, userOpCalldata
        );

        ops[0] = userOp;

        // Execute the operation
        startPrank(BUNDLER.addr);
        uint256 gasValue = gasleft();

        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                0,
                "AA33 reverted",
                abi.encodeWithSelector(IStartaleTokenPaymasterEventsAndErrors.InsufficientERC20Balance.selector)
            )
        );

        ENTRYPOINT.handleOps(ops, payable(BUNDLER.addr));
        gasValue = gasValue - gasleft();
        stopPrank();
    }

    function test_Success_test_UpdateNativeOracleConfig() external {
        vm.startPrank(PAYMASTER_OWNER.addr);
        vm.expectEmit(true, true, false, false, address(tokenPaymaster));
        emit IOracleHelper.NativeOracleConfigUpdated(
            IOracleHelper.NativeOracleConfig({maxOracleRoundAge: 1000, nativeAssetDecimals: 18})
        );
        tokenPaymaster.updateNativeOracleConfig(
            IOracleHelper.NativeOracleConfig({maxOracleRoundAge: 1000, nativeAssetDecimals: 18})
        );
        vm.stopPrank();
    }

    function test_DoesNotRevertIf_Mismatching_Oracle_Decimals_Independent_Mode() external {
        vm.warp(1742296776);
        tokenPaymaster.deposit{value: 10 ether}();
        testToken.mint(address(ALICE_ACCOUNT), 100_000 * (10 ** testToken.decimals()));

        vm.startPrank(PAYMASTER_OWNER.addr);
        tokenPaymaster.setUnaccountedGas(40_000);
        vm.stopPrank();

        // Warm up the ERC20 balance slot for tokenFeeTreasury by making some tokens held initially
        testToken.mint(PAYMASTER_FEE_COLLECTOR.addr, 100_000 * (10 ** testToken.decimals()));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);

        // Good part of not doing pre-charge and only charging in postOp is we can give approval during the execution phase.
        // So we build a userOp with approve calldata.
        bytes memory userOpCalldata = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(testToken),
            0,
            abi.encodeWithSelector(testToken.approve.selector, address(tokenPaymaster), 1000 * 1e18)
        );

        tokenToUsdOracle.setPriceDecimals(10);

        vm.startPrank(PAYMASTER_OWNER.addr);
        vm.expectEmit(true, true, false, false, address(tokenPaymaster));
        emit IOracleHelper.TokenOracleConfigUpdated(
            address(testToken),
            IOracleHelper.TokenOracleConfig({tokenOracle: IOracle(address(tokenToUsdOracle)), maxOracleRoundAge: 500})
        );
        tokenPaymaster.updateTokenOracleConfig(
            address(testToken),
            IOracleHelper.TokenOracleConfig({tokenOracle: IOracle(address(tokenToUsdOracle)), maxOracleRoundAge: 500})
        );
        vm.stopPrank();
        // Generate and sign the token paymaster data
        (PackedUserOperation memory userOp, bytes32 userOpHash) = createUserOpWithTokenPaymasterAndIndependentMode(
            ALICE, tokenPaymaster, address(testToken), 100_000, userOpCalldata
        );

        ops[0] = userOp;

        // Execute the operation
        startPrank(BUNDLER.addr);
        uint256 gasValue = gasleft();

        ENTRYPOINT.handleOps(ops, payable(BUNDLER.addr));
        gasValue = gasValue - gasleft();
        stopPrank();
    }

    function test_RevertIf_DeployWithSignerSetToZero() external {
        address[] memory signers = new address[](2);
        signers[0] = PAYMASTER_SIGNER_A.addr;
        signers[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(MultiSigners.SignerAddressCannotBeZero.selector));
        // Deploy the token paymaster
        StartaleTokenPaymaster testArtifact = new StartaleTokenPaymaster(
            PAYMASTER_OWNER.addr,
            ENTRYPOINT_ADDRESS,
            signers,
            PAYMASTER_FEE_COLLECTOR.addr,
            TOKEN_PM_UNACCOUNTED_GAS, // unaccounted gas
            address(nativeAssetToUsdOracle),
            address(0),
            MAX_ORACLE_ROUND_AGE,
            18, // native token decimals
            _toSingletonArray(address(testToken)),
            _toSingletonArray(1e6),
            _toSingletonArray(
                IOracleHelper.TokenOracleConfig({
                    tokenOracle: IOracle(address(tokenToUsdOracle)),
                    maxOracleRoundAge: MAX_ORACLE_ROUND_AGE
                })
            )
        );
    }

    function test_RevertIf_UnaccountedGasTooHigh() external prankModifier(PAYMASTER_OWNER.addr) {
        vm.expectRevert(IStartaleTokenPaymasterEventsAndErrors.UnaccountedGasTooHigh.selector);
        tokenPaymaster.setUnaccountedGas(100_000_000);
    }

    function test_Allow_Treasury_ToBeSelf() public {
        address[] memory signers = new address[](2);
        signers[0] = PAYMASTER_SIGNER_A.addr;
        signers[1] = PAYMASTER_SIGNER_B.addr;
        StartaleTokenPaymaster testArtifact = new StartaleTokenPaymaster(
            PAYMASTER_OWNER.addr,
            ENTRYPOINT_ADDRESS,
            signers,
            PAYMASTER_FEE_COLLECTOR.addr,
            TOKEN_PM_UNACCOUNTED_GAS, // unaccounted gas
            address(nativeAssetToUsdOracle),
            address(0),
            MAX_ORACLE_ROUND_AGE,
            18, // native token decimals
            _toSingletonArray(address(testToken)),
            _toSingletonArray(1e6),
            _toSingletonArray(
                IOracleHelper.TokenOracleConfig({
                    tokenOracle: IOracle(address(tokenToUsdOracle)),
                    maxOracleRoundAge: MAX_ORACLE_ROUND_AGE
                })
            )
        );

        vm.startPrank(PAYMASTER_OWNER.addr);
        testArtifact.setTokenFeesTreasury(address(testArtifact));
        vm.stopPrank();
        assertEq(testArtifact.tokenFeesTreasury(), address(testArtifact));
    }

    function test_RevertIf_FeeTreasuryIsZero() external {
        address[] memory signers = new address[](2);
        signers[0] = PAYMASTER_SIGNER_A.addr;
        signers[1] = PAYMASTER_SIGNER_B.addr;
        vm.expectRevert(
            abi.encodeWithSelector(IStartaleTokenPaymasterEventsAndErrors.InvalidTokenFeesTreasury.selector)
        );
        // Deploy the token paymaster
        StartaleTokenPaymaster testArtifact = new StartaleTokenPaymaster(
            PAYMASTER_OWNER.addr,
            ENTRYPOINT_ADDRESS,
            signers,
            address(0),
            TOKEN_PM_UNACCOUNTED_GAS, // unaccounted gas
            address(nativeAssetToUsdOracle),
            address(0),
            MAX_ORACLE_ROUND_AGE,
            18, // native token decimals
            _toSingletonArray(address(testToken)),
            _toSingletonArray(1e6),
            _toSingletonArray(
                IOracleHelper.TokenOracleConfig({
                    tokenOracle: IOracle(address(tokenToUsdOracle)),
                    maxOracleRoundAge: MAX_ORACLE_ROUND_AGE
                })
            )
        );
    }

    function test_RevertIf_InvalidSignature_ExternalMode() external {
        tokenPaymaster.deposit{value: 10 ether}();
        testToken.mint(address(ALICE_ACCOUNT), 100_000 * (10 ** testToken.decimals()));

        vm.startPrank(PAYMASTER_OWNER.addr);
        tokenPaymaster.setUnaccountedGas(40_000);
        vm.stopPrank();

        // Warm up the ERC20 balance slot for tokenFeeTreasury by making some tokens held initially
        testToken.mint(PAYMASTER_FEE_COLLECTOR.addr, 100_000 * (10 ** testToken.decimals()));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);

        uint256 exchangeRate = 1e18; // Assume 1 token = 1 native token = 1 USD ?
        uint32 externalFeeMarkup = 1e6; // no premium

        // Good part of not doing pre-charge and only charging in postOp is we can give approval during the execution phase.
        // So we build a userOp with approve calldata.
        bytes memory userOpCalldata = abi.encodeWithSelector(
            SimpleAccount.execute.selector,
            address(testToken),
            0,
            abi.encodeWithSelector(testToken.approve.selector, address(tokenPaymaster), 1000 * 1e18)
        );

        // Generate and sign the token paymaster data
        (PackedUserOperation memory userOp, bytes32 userOpHash) = createUserOpWithTokenPaymasterAndExternalMode(
            ALICE, tokenPaymaster, address(testToken), exchangeRate, externalFeeMarkup, 100_000, userOpCalldata
        );

        bytes memory paymasterAndData = userOp.paymasterAndData;
        // Tamper the signature by altering the last byte
        paymasterAndData[paymasterAndData.length - 1] = bytes1(uint8(paymasterAndData[paymasterAndData.length - 1]) + 1);
        userOp.paymasterAndData = paymasterAndData;

        userOp.signature = signUserOp(ALICE, userOp);

        ops[0] = userOp;

        // Execute the operation
        startPrank(BUNDLER.addr);
        uint256 gasValue = gasleft();

        // bytes memory expectedRevertReason = abi.encodeWithSelector(
        //     IEntryPoint.FailedOpWithRevert.selector,
        //     0,
        //     "AA33 reverted",
        //     abi.encodeWithSelector(IStartaleTokenPaymasterEventsAndErrors.PotentiallyMalformedSignature.selector)
        // );
        // vm.expectRevert(expectedRevertReason);
        vm.expectRevert();

        ENTRYPOINT.handleOps(ops, payable(BUNDLER.addr));
        gasValue = gasValue - gasleft();
        stopPrank();
    }

    function test_SetPriceMarkupTooHigh() external prankModifier(PAYMASTER_OWNER.addr) {
        vm.expectRevert(IStartaleTokenPaymasterEventsAndErrors.FeeMarkupTooHigh.selector);
        tokenPaymaster.addSupportedToken(
            address(testToken),
            2e6 + 1,
            IOracleHelper.TokenOracleConfig({tokenOracle: IOracle(address(tokenToUsdOracle)), maxOracleRoundAge: 1000})
        );
    }

    function test_AddVerifyingSigner() external prankModifier(PAYMASTER_OWNER.addr) {
        assertEq(tokenPaymaster.isSigner(PAYMASTER_SIGNER_A.addr), true);
        assertEq(tokenPaymaster.isSigner(PAYMASTER_SIGNER_B.addr), true);
        address newSigner = address(0x123);
        assertEq(tokenPaymaster.isSigner(newSigner), false);
        vm.expectEmit(true, true, false, true, address(tokenPaymaster));
        emit MultiSigners.SignerAdded(newSigner);
        tokenPaymaster.addSigner(newSigner);
        assertEq(tokenPaymaster.isSigner(newSigner), true);
    }

    function test_RemoveVerifyingSigner() external prankModifier(PAYMASTER_OWNER.addr) {
        assertEq(tokenPaymaster.isSigner(PAYMASTER_SIGNER_A.addr), true);
        assertEq(tokenPaymaster.isSigner(PAYMASTER_SIGNER_B.addr), true);
        vm.expectEmit(true, true, false, true, address(tokenPaymaster));
        emit MultiSigners.SignerRemoved(PAYMASTER_SIGNER_B.addr);
        tokenPaymaster.removeSigner(PAYMASTER_SIGNER_B.addr);
        assertEq(tokenPaymaster.isSigner(PAYMASTER_SIGNER_B.addr), false);
    }

    // TODO: More Tests Can be Added For..
    // Invalid Mode
    // Invalid Signature Length
    // Invalid Mode Specific Data
}
