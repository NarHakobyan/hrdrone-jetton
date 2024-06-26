import { mnemonicToPrivateKey } from '@ton/crypto';
import * as dotenv from 'dotenv';
import {
  Address,
  beginCell,
  contractAddress,
  fromNano,
  internal,
  JettonMaster,
  toNano,
  TonClient4,
  WalletContractV4,
} from 'ton';

import { StakingContract, storeTokenTransfer } from './output/SampleJetton_StakingContract';
import { deploy } from './utils/deploy';
import { printAddress, printDeploy, printHeader, printSeparator } from './utils/print';

dotenv.config();

(async () => {
  //create client for testnet sandboxv4 API - alternative endpoint
  const client4 = new TonClient4({
    endpoint: 'https://sandbox-v4.tonhubapi.com',
  });
  const mnemonics = (process.env.mnemonics || '').toString(); // 🔴 Change to your own

  const keyPair = await mnemonicToPrivateKey(mnemonics.split(' '));
  const secretKey = keyPair.secretKey;
  const workchain = 0; //we are working in basechain.
  const deployer_wallet = WalletContractV4.create({ workchain, publicKey: keyPair.publicKey });
  const deployer_wallet_contract = client4.open(deployer_wallet);

  const jettonMaster_address = Address.parse('JETTON TOKEN ROOT'); // 🔴 Jetton Root, the token Address you want to support

  const staking_init = await StakingContract.init(jettonMaster_address, deployer_wallet.address, 15_000n);
  const stakingContract_address = contractAddress(workchain, staking_init);
  const packed_stake = beginCell().storeUint(300, 64).endCell();
  const packed = beginCell()
    .store(
      storeTokenTransfer({
        $$type: 'TokenTransfer',
        queryId: 0n,
        amount: toNano('13.333333'), // using toNano to convert to human readable unit
        destination: stakingContract_address,
        response_destination: deployer_wallet_contract.address, // Original Owner, aka. First Minter's Jetton Wallet
        custom_payload: null,
        forward_ton_amount: toNano('0.0333'), // Important! Need have tiny amount TONcoin to pass through
        forward_payload: packed_stake,
      }),
    )
    .endCell();

  const deployAmount = toNano('0.3');
  const seqno: number = await deployer_wallet_contract.getSeqno();
  const balance: bigint = await deployer_wallet_contract.getBalance();

  const client_for_jetton = client4.open(await new JettonMaster(jettonMaster_address));
  const deployer_jetton_wallet = await client_for_jetton.getWalletAddress(deployer_wallet.address);
  console.log("🛠️ Calling To Deployer's JettonWallet:\n" + deployer_jetton_wallet + '\n');

  printSeparator();
  console.log('🛠️ Deployer: ' + deployer_wallet_contract.address + ' sending Txs');
  console.log("🔴 Deployer's JettonWallet:");
  console.log(deployer_jetton_wallet + '(for this jetton token)');
  console.log('');
  console.log('Current deployment wallet balance =', fromNano(balance).toString(), '💎TON\n\n');
  printSeparator();

  const staking_contract_jetton_wallet = await client_for_jetton.getWalletAddress(stakingContract_address);
  console.log('🟡 StakingContract: ' + stakingContract_address);
  console.log('🟡 Receive Jetton, JettonWallet=> \n' + staking_contract_jetton_wallet);

  await deployer_wallet_contract.sendTransfer({
    seqno,
    secretKey,
    messages: [
      internal({
        to: deployer_jetton_wallet,
        value: deployAmount,
        bounce: true,
        body: packed,
      }),
    ],
  });
})();
