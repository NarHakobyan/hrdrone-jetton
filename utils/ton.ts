import { getHttpEndpoint } from '@orbs-network/ton-access';
import { mnemonicToWalletKey } from '@ton/crypto';
import type { OpenedContract } from '@ton/ton';
import { TonClient, WalletContractV4 } from '@ton/ton';
import { beginCell } from '@ton/core';

export async function getTonClient(): Promise<TonClient> {
  const endpoint = await getHttpEndpoint({ network: process.env.ENABLE_MAINNET ? 'mainnet' : 'testnet' });

  return new TonClient({ endpoint });
}

export async function loadWallet(client: TonClient, mnemonic: string = process.env.TON_MNEMONIC!) {
  const key = await mnemonicToWalletKey(mnemonic.split(' '));
  const wallet = WalletContractV4.create({ publicKey: key.publicKey, workchain: 0 });

  if (!(await client.isContractDeployed(wallet.address))) {
    throw new Error('Wallet is not deployed');
  }

  const contract = client.open(wallet);
  const sender = contract.sender(key.secretKey);

  return { wallet, contract, sender };
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function waitForTransaction(seqno: number, walletContract: OpenedContract<WalletContractV4>) {
  let currentSeqno = seqno;

  while (currentSeqno === seqno) {
    console.log(`waiting for the transaction (seqno: ${seqno}) to confirm...`);
    await sleep(1500);
    currentSeqno = await walletContract.getSeqno();
  }

  console.log(`Tx (seqno: ${seqno}) confirmed!`);
}

export function keyToInt(publicKey: Buffer) {
  return beginCell().storeBuffer(publicKey).endCell().beginParse().loadUintBig(256);
}
