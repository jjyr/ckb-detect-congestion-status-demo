api = Ckb::Api.new
api.load_default_configuration!
bob = Ckb::Wallet.from_hex(api, "e79f3207ea4980b7fed79956d5934249ceac4751a4fae01a0f7c4a96884bc4e3")

asw.send_capacity(bob.address, 100000)
bob.get_balance

alice = Ckb::Wallet.from_hex(api, "76e853efa8245389e33f6fe49dcbd359eb56be2f6c3594e12521d2a806d32156")
bob.send_capacity(alice.address, 12345)

token_info = bob.created_token_info("Token 1")
bob_token1 = bob.udt_wallet(token_info)
alice_token1 = alice.udt_wallet(token_info)

bob.create_udt_token(10000, "Token 1", 10000000)
bob_token1.get_balance

bob_plasma_account = Ckb::PLASMATokenAccount.new(api: api, udt_wallet: bob_token1)

