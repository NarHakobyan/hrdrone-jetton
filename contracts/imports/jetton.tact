import "@stdlib/ownable";

import "./jetton-structs";
import "./jetton-messages";

// ============================================================================================================ //
@interface("org.ton.jetton.master")
trait Jetton with Ownable {

  total_supply: Int; // Already set initially
  mintable: Bool;
  owner: Address;
  content: Cell;

  max_supply: Int; // This is not in the TEP-74 interface

  receive(msg: TokenUpdateContent) {
    self.requireOwner();                // Allow changing content only by owner
    self.content = msg.content;         // Update content
  }

  receive(msg: TokenBurnNotification) {
    self.requireWallet(msg.owner);                     // Check wallet
    self.total_supply = self.total_supply - msg.amount; // Update supply

    if (msg.response_destination != null) {
      // Cashback
      send(SendParameters{
      to: msg.response_destination!!,
      value: 0,
      bounce: false,
      mode: SendRemainingValue + SendIgnoreErrors,
      body: TokenExcesses{
      query_id: msg.query_id
      }.toCell()
      });
    }
  }

  // @to The Address receive the Jetton token after minting
  // @amount The amount of Jetton token being minted
  // @response_destination The previous owner address
  fun mint(to: Address, amount: Int, response_destination: Address) {
    require(self.total_supply + amount <= self.max_supply, "The total supply will be overlapping.");
    self.total_supply = self.total_supply + amount; // Update total supply

    let winit: StateInit = self.getJettonWalletInit(to); // Create message
    send(SendParameters{
    to: contractAddress(winit),
    value: 0,
    bounce: false,
    mode: SendRemainingValue,
    body: TokenTransferInternal{
    query_id: 0,
    amount: amount,
    from: myAddress(),
    response_destination: response_destination,
    forward_ton_amount: 0,
    forward_payload: emptySlice()
    }.toCell(),
    code: winit.code,
    data: winit.data
    });
  }

  fun requireWallet(owner: Address) {
    let ctx: Context = context();
    let winit: StateInit = self.getJettonWalletInit(owner);
    require(contractAddress(winit) == ctx.sender, "Invalid sender");
  }

  virtual fun getJettonWalletInit(address: Address): StateInit {
    return initOf JettonDefaultWallet(myAddress(), address);
  }

  // ====== Get Methods ====== //
  get fun get_jetton_data(): JettonData {
    let code: Cell = self.getJettonWalletInit(myAddress()).code;
    return JettonData{
    total_supply: self.total_supply,
    mintable: self.mintable,
    owner: self.owner,
    content: self.content,
    wallet_code: code
    };
  }

  get fun get_wallet_address(owner: Address): Address {
    let winit: StateInit = self.getJettonWalletInit(owner);
    return contractAddress(winit);
  }
}
// ============================================================ //
@interface("org.ton.jetton.wallet")
contract JettonDefaultWallet {
  const min_tons_for_storage: Int = ton("0.01");
  const gas_consumption: Int = ton("0.01");

  balance: Int;
  owner: Address;
  master: Address;

  init(master: Address, owner: Address) {
    self.balance = 0;
    self.owner = owner;
    self.master = master;
  }

  receive(msg: TokenTransfer) {
    // 0xf8a7ea5
    let ctx: Context = context(); // Check sender
    require(ctx.sender == self.owner, "Invalid sender");

    // Gas checks
    let fwdFee: Int = ctx.readForwardFee() + ctx.readForwardFee();
    let final: Int =  2 * self.gas_consumption + self.min_tons_for_storage + fwdFee;
    require(ctx.value > min(final, ton("0.01")), "Invalid value!!");

    // Update balance
    self.balance = self.balance - msg.amount;
    require(self.balance >= 0, "Invalid balance");

    let init: StateInit = initOf JettonDefaultWallet(self.master, msg.destination);
    let walletAddress: Address = contractAddress(init);
    send(SendParameters{
    to: walletAddress,
    value: 0,
    mode: SendRemainingValue,
    bounce: false,
    body: TokenTransferInternal{
    query_id: msg.query_id,
    amount: msg.amount,
    from: self.owner,
    response_destination: msg.response_destination,
    forward_ton_amount: msg.forward_ton_amount,
    forward_payload: msg.forward_payload
    }.toCell(),
    code: init.code,
    data: init.data
    });
  }

  receive(msg: TokenTransferInternal) {
    // 0x178d4519
    let ctx: Context = context();

    if (ctx.sender != self.master) {
      let sinit: StateInit = initOf JettonDefaultWallet(self.master, msg.from);
      require(contractAddress(sinit) == ctx.sender, "Invalid sender!");
    }

    // Update balance
    self.balance = self.balance + msg.amount;
    require(self.balance >= 0, "Invalid balance");

    // Get value for gas
    let msgValue: Int = self.msgValue(ctx.value);
    let fwdFee: Int = ctx.readForwardFee();
    msgValue = msgValue - msg.forward_ton_amount - fwdFee;

    // 0x7362d09c - notify the new owner of JettonToken that the transfer is complete
    if (msg.forward_ton_amount > 0) {
      send(SendParameters{
      to: self.owner,
      value: msg.forward_ton_amount,
      mode: SendPayGasSeparately + SendIgnoreErrors,
      bounce: false,
      body: TokenNotification {
      query_id: msg.query_id,
      amount: msg.amount,
      from: msg.from,
      forward_payload: msg.forward_payload
      }.toCell()
      });
    }

    // 0xd53276db -- Cashback to the original Sender
    if (msg.response_destination != null) {
      send(SendParameters {
      to: msg.response_destination,
      value: msgValue,
      bounce: false,
      body: TokenExcesses {
      query_id: msg.query_id
      }.toCell(),
      mode: SendIgnoreErrors
      });
    }
  }

  receive(msg: TokenBurn) {
    let ctx: Context = context();
    require(ctx.sender == self.owner, "Invalid sender");  // Check sender

    self.balance = self.balance - msg.amount; // Update balance
    require(self.balance >= 0, "Invalid balance");

    let fwdFee: Int = ctx.readForwardFee(); // Gas checks
    require(ctx.value > fwdFee + 2 * self.gas_consumption + self.min_tons_for_storage, "Invalid value - Burn");

    // Burn tokens
    send(SendParameters{
    to: self.master,
    value: 0,
    mode: SendRemainingValue,
    bounce: true,
    body: TokenBurnNotification{
    query_id: msg.query_id,
    amount: msg.amount,
    owner: self.owner,
    response_destination: self.owner
    }.toCell()
    });
  }

  get fun msgValue(value: Int): Int {
    let msgValue: Int = value;
    let tonBalanceBeforeMsg: Int = myBalance() - msgValue;
    let storageFee: Int = self.min_tons_for_storage - min(tonBalanceBeforeMsg, self.min_tons_for_storage);
    msgValue = msgValue - (storageFee + self.gas_consumption);
    return msgValue;
  }

  bounced(src: bounced<TokenTransferInternal>) {
    self.balance = self.balance + src.amount;
  }

  bounced(src: bounced<TokenBurnNotification>) {
    self.balance = self.balance + src.amount;
  }

  get fun get_wallet_data(): JettonWalletData {
    return JettonWalletData{
    balance: self.balance,
    owner: self.owner,
    master: self.master,
    wallet_code: (initOf JettonDefaultWallet(self.master, self.owner)).code
    };
  }
}
