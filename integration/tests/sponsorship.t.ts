import { equal } from "assert";
import {
  createPublicClient,
  createWalletClient,
  type PrivateKeyAccount,
  encodePacked,
  toBytes,
  fromHex,
  http,
  type PublicClient,
  type WalletClient,
  parseEther,
  encodeFunctionData,
  type Address,
  type Hex,
} from "viem";
import {
  type BundlerClient,
  createBundlerClient,
  toPackedUserOperation,
  type UserOperation,
} from "viem/account-abstraction";
import { localhost } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { toSimpleSmartAccount } from "permissionless/accounts";
import { expect } from "chai";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

const __dirname = import.meta.dirname;

dotenv.config();

const MOCK_SPONSOR_ACCOUNT =
  "0x0000000000000000000000000000000000001234" as Address;
const MOCK_VALID_UNTIL = 0;
const MOCK_VALID_AFTER = 0;
const MOCK_SIG = "0x1234";
// Need this to pass condition on the paymaster contract
const MOCK_DYNAMIC_ADJUSTMENT = 1100000;

const DUMMY_PAYMASTER_VERIFICATION_GAS_LIMIT = BigInt(251165);
const DUMMY_PAYMASTER_POST_OP_GAS_LIIMIT = BigInt(100000);

function getPaymasterData(validUntil: number, validAfter: number) {
  const data = {
    sponsorAccount: MOCK_SPONSOR_ACCOUNT,
    validUntil,
    validAfter,
    feeMarkup: MOCK_DYNAMIC_ADJUSTMENT,
  };

  return encodePacked(
    ["address", "uint48", "uint48", "uint32"],
    [data.sponsorAccount, data.validUntil, data.validAfter, data.feeMarkup]
  );
}

// Todo: Convert this to hardhat based tests so that we can attach EP address and can interact directly with artifacts

describe("EntryPoint v0.7 with SponsorshipPaymaster", () => {
  let paymasterAddress: Address;
  let entryPointAddress: Address;
  let simpleAccountFactoryAddress: Address;
  let counterAddress: Address;

  let publicClient: PublicClient;
  let walletClient: WalletClient;
  let bundlerClient: BundlerClient;

  let entryPointAbi;
  let sponsorshipPaymasterAbi;
  let counterAbi;

  let simpleAccountOwnerPrivateKey: Hex;
  let simpleAccountOwnerAccount: PrivateKeyAccount;
  let paymasterSignerPrivateKey: Hex;
  let paymasterSignerAccount: PrivateKeyAccount;
  let paymasterOwnerPrivateKey: Hex;
  let paymasterOwnerAccount: PrivateKeyAccount;

  async function fillPaymasterDataSignature(
    userOperation: UserOperation,
    fundingId: Address,
    validUntil: number,
    validAfter: number,
    feeMarkup: number
  ): Promise<UserOperation> {
    const hash = await publicClient.readContract({
      address: paymasterAddress,
      abi: sponsorshipPaymasterAbi,
      functionName: "getHash",
      args: [
        toPackedUserOperation(userOperation),
        fundingId,
        validUntil,
        validAfter,
        feeMarkup,
      ],
    });
    const sig = await walletClient.signMessage({
      account: paymasterSignerAccount,
      message: { raw: toBytes(hash as Hex) },
    });
    userOperation.paymasterData = encodePacked(
      ["bytes", "bytes"],
      [userOperation.paymasterData, sig]
    );
    return userOperation;
  }

  before(async () => {
    let bundlerURL = process.env.BUNDLER_URL ?? "http://localhost:3000";

    paymasterAddress = process.env.PAYMASTER_ADDRESS as Address;
    entryPointAddress = process.env.ENTRY_POINT_ADDRESS as Address;
    simpleAccountFactoryAddress = process.env.SIMPLE_ACCOUNT_FACTORY as Address;
    counterAddress = process.env.COUNTER_ADDRESS as Address;

    // Simple Account Owner
    simpleAccountOwnerPrivateKey = process.env
      .SIMPLE_ACCOUNT_OWNER_PRIVATE_KEY as Hex;
    simpleAccountOwnerAccount = privateKeyToAccount(
      simpleAccountOwnerPrivateKey
    );

    // Paymaster Signer
    paymasterSignerPrivateKey = process.env.PAYMASTER_SIGNER_PRIVATE_KEY as Hex;
    paymasterSignerAccount = privateKeyToAccount(paymasterSignerPrivateKey);

    // Paymaster Owner
    paymasterOwnerPrivateKey = process.env.PAYMASTER_OWNER_PRIVATE_KEY as Hex;
    paymasterOwnerAccount = privateKeyToAccount(paymasterOwnerPrivateKey);

    entryPointAbi = JSON.parse(
      fs.readFileSync(
        path.resolve(__dirname, "../abis/EntryPoint.json"),
        "utf8"
      )
    );
    sponsorshipPaymasterAbi = JSON.parse(
      fs.readFileSync(
        path.resolve(__dirname, "../abis/SponsorshipPaymaster.json"),
        "utf8"
      )
    );
    counterAbi = JSON.parse(
      fs.readFileSync(
        path.resolve(__dirname, "../abis/TestCounter.json"),
        "utf8"
      )
    );

    // @ts-ignore
    publicClient = createPublicClient({
      chain: localhost,
      transport: http(),
    });

    walletClient = createWalletClient({
      chain: localhost,
      transport: http(),
    });

    bundlerClient = createBundlerClient({
      // @ts-ignore
      client: publicClient,
      transport: http(bundlerURL),
    });

    const [defaultWalletAddress] = await walletClient.getAddresses();
    // @ts-ignore
    await walletClient.sendTransaction({
      account: paymasterOwnerAccount,
      to: paymasterAddress,
      value: parseEther("2"),
      data: encodeFunctionData({
        abi: sponsorshipPaymasterAbi,
        functionName: "addStake",
        args: [2],
      }),
    });

    console.log("paymaster address ", paymasterAddress);

    // Deposit ETH to Paymaster address in EntryPoint contract
    // @ts-ignore
    await walletClient.sendTransaction({
      account: defaultWalletAddress,
      to: entryPointAddress,
      value: parseEther("1"),
      data: encodeFunctionData({
        abi: entryPointAbi,
        functionName: "depositTo",
        args: [paymasterAddress],
      }),
    });

    // Todo: Review below action and type errors.
    await walletClient.sendTransaction({
      account: defaultWalletAddress,
      to: paymasterAddress,
      value: parseEther("1"),
      data: encodeFunctionData({
        abi: sponsorshipPaymasterAbi,
        functionName: "depositFor",
        args: [MOCK_SPONSOR_ACCOUNT],
      }),
    });

    const currentDeposit = await publicClient.readContract({
      address: paymasterAddress,
      abi: sponsorshipPaymasterAbi,
      functionName: "getBalance",
      args: [MOCK_SPONSOR_ACCOUNT],
    });
    console.log("currentDeposit ", currentDeposit);
  });

  describe("#parsePaymasterAndData", () => {
    it("should parse data properly", async () => {
      const paymasterAndData = encodePacked(
        [
          "address", // paymaster
          "uint128", // paymasterVerificationGasLimit
          "uint128", // paymasterPostOpGasLimit
          "address", // sponsorAccount
          "uint48", // validUntil
          "uint48", // validAfter
          "uint32", // feeMarkup
          "bytes", // signature
        ],
        [
          paymasterAddress,
          BigInt(100000),
          BigInt(100000),
          MOCK_SPONSOR_ACCOUNT,
          MOCK_VALID_UNTIL,
          MOCK_VALID_AFTER,
          MOCK_DYNAMIC_ADJUSTMENT,
          MOCK_SIG,
        ]
      );
      console.log("paymasterAndData ", paymasterAndData);

      const res = await publicClient.readContract({
        address: paymasterAddress,
        abi: sponsorshipPaymasterAbi,
        functionName: "parsePaymasterAndData",
        args: [paymasterAndData],
      });

      expect(res[0]).to.be.equal(MOCK_SPONSOR_ACCOUNT);
      expect(res[1]).to.be.equal(MOCK_VALID_UNTIL);
      expect(res[2]).to.be.equal(MOCK_VALID_AFTER);
      expect(res[3]).to.be.equal(MOCK_DYNAMIC_ADJUSTMENT);
      expect(res[4]).to.be.equal(BigInt(100000));
      expect(res[5]).to.be.equal(BigInt(100000));
      expect(res[6]).to.be.equal(MOCK_SIG);
    });
  });

  describe("#succeed with valid signature", () => {
    it("Counter incremented sponsored by Paymaster", async () => {
      // Create a simple smart account
      const simpleAccount = await toSimpleSmartAccount({
        // @ts-ignore
        client: publicClient,
        owner: simpleAccountOwnerAccount,
        factoryAddress: simpleAccountFactoryAddress,
        entryPoint: {
          address: entryPointAddress,
          version: "0.7",
        },
      });

      // Hold pre user operation data
      const preAccountBalance = await publicClient.getBalance({
        address: simpleAccount.address,
      });
      const preCounterValue = await publicClient
        .call({
          to: counterAddress,
          data: encodeFunctionData({
            abi: counterAbi,
            functionName: "counters",
            args: [simpleAccount.address],
          }),
        })
        .then((response) => fromHex(response.data, "number"));

      // @ts-ignore
      // base user op preparation doesn't necessarilly call prepareUserOperation, we can craft user op object locally
      let baseUserOp = await bundlerClient.prepareUserOperation({
        account: simpleAccount,
        calls: [
          {
            to: counterAddress,
            // @ts-ignore
            value: 0n,
            // @ts-ignore
            data: encodeFunctionData({
              abi: counterAbi,
              functionName: "count",
            }),
          },
        ],
      });

      // console.log("baseUserOp ", baseUserOp);

      // Prepare paymaster data
      const paymasterData = getPaymasterData(
        MOCK_VALID_UNTIL,
        MOCK_VALID_AFTER
      );

      // Todo: Review type complaints
      baseUserOp.paymaster = paymasterAddress;
      baseUserOp.paymasterData = paymasterData;
      baseUserOp.paymasterVerificationGasLimit =
        DUMMY_PAYMASTER_VERIFICATION_GAS_LIMIT;
      baseUserOp.paymasterPostOpGasLimit = DUMMY_PAYMASTER_POST_OP_GAS_LIIMIT;

      // Todo: Review type complaints
      baseUserOp = await fillPaymasterDataSignature(
        baseUserOp,
        MOCK_SPONSOR_ACCOUNT,
        MOCK_VALID_UNTIL,
        MOCK_VALID_AFTER,
        MOCK_DYNAMIC_ADJUSTMENT
      );

      // for gas estimation, use dummy signarure
      // What's dummy signature? useful links, https://www.alchemy.com/blog/erc-4337-gas-estimation#user-operation-flow, https://www.alchemy.com/blog/dummy-signatures-and-gas-token-transfers#how-to-calculate-dummy-signature-values
      const dummySignature =
        "0xfffffffffffffffffffffffffffffff0000000000000000000000000000000007aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1c";
      const estimatedGas = await bundlerClient.estimateUserOperationGas({
        ...baseUserOp,
        signature: dummySignature,
      });

      // Todo: Review type complaints
      let userOp = {
        ...baseUserOp,
        callGasLimit: estimatedGas.callGasLimit,
        preVerificationGas: estimatedGas.preVerificationGas + BigInt(5000), // TODO: Rundler deny without extra gas to estimated value, need investigation
        verificationGasLimit: estimatedGas.verificationGasLimit,
        paymasterVerificationGasLimit:
          estimatedGas.paymasterVerificationGasLimit,
        paymasterData: paymasterData, // reset paymaster data to remove previous signature for gas estimation
      };
      // @ts-ignore
      userOp = await fillPaymasterDataSignature(
        userOp,
        MOCK_SPONSOR_ACCOUNT,
        MOCK_VALID_UNTIL,
        MOCK_VALID_AFTER,
        MOCK_DYNAMIC_ADJUSTMENT
      );

      // Send User Operation
      // @ts-ignore
      const userOpHash = await bundlerClient.sendUserOperation({
        ...userOp,
        signature: null, // don't use previous account signature, need to sign inside `sendUserOperation` again
      });

      await bundlerClient.waitForUserOperationReceipt({
        hash: userOpHash,
      });

      // Check account balance not changed
      const postAccountBalance = await publicClient.getBalance({
        address: simpleAccount.address,
      });
      equal(postAccountBalance, preAccountBalance);

      // Check counter value incremented
      const postCounter = await publicClient
        .call({
          to: counterAddress,
          data: encodeFunctionData({
            abi: counterAbi,
            functionName: "counters",
            args: [simpleAccount.address],
          }),
        })
        .then((response) => fromHex(response.data, "number"));

      equal(postCounter, preCounterValue + 1);
    });
  });
});
