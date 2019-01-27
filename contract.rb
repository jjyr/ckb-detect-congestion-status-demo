# This contract simulate PLASMA deposit and withdraw operations.
#
# We distinguish output cells by type, into UDT and PLASMA token(which type equals to this contract) to make our description more clear. 
#
# This contract needs 1 signed argument:
# udt_type_hash, to determine which UDT token deposited.
# This contract also needs 1 unsigned argument:
# token_status, to determine status of PLASMA token.
#

if ARGV.length < 2
  raise "Not enough arguments!"
end

# 100 block
BASE_CHALLENGE_PERIOD = 100

# BLOCK max cycles by consensus
BLOCK_MAX_CYCLES = 100000000

# arguments
def udt_type_hash
  ARGV[0]
end

def token_status
  ARGV[1]
end

# PLASMA token should be this type
def contract_type_hash(status)
  $contract_type_hash ||= CKB.load_script_hash(0, CKB::Source::CURRENT, CKB::Category::TYPE)
end

def current_block_height
  $current_block_height ||= CKB.load_ancestor_block_info(0)['number'] + 1
end

def is_chain_congestion?(start_block_height, end_block_height)
  blocks = (start_block_height..end_block_height).map do |i| 
    CKB.load_ancestor_block_info(current_block_height - i)
  end
  # return false because we lost block info
  if blocks[0].nil?
    false
  end
  consider_full_cycles = BLOCK_MAX_CYCLES * 0.95
  blocks.all? do |block|
    block["txs_cycles"].to_i > consider_full_cycles
  end
end

# dynamic determine challenge period based on chain congestion status
def tolerant_challenge_period(start_block_height)
  challenge_end_block_height = start_block_height + BASE_CHALLENGE_PERIOD
  while is_chain_congestion?(start_block_height, challenge_end_block_height) &&
      current_block_height >= challenge_end_block_height
    challenge_end_block_height += BASE_CHALLENGE_PERIOD
    start_block_height += BASE_CHALLENGE_PERIOD
  end
  challenge_end_block_height
end

class UDT
  def initialize(source, index)
    @source = source
    @index = index
  end

  def read_token_count
    CKB::CellField.new(@source, @index, CKB::CellField::DATA).read(0, 8).unpack("Q<")[0]
  end

  def read_type_hash
    CKB.load_script_hash(@index, @source, CKB::Category::TYPE)
  end

  def read_lock_hash
    CKB.load_script_hash(i, CKB::Source::INPUT, CKB::Category::LOCK)
  end
end

class PLASMAToken
  def initialize(source, index)
    @source = source
    @index = index
  end

  def read_token_count
    CKB::CellField.new(@source, @index, CKB::CellField::DATA).read(0, 8).unpack("Q<")[0]
  end

  def read_type_hash
    CKB.load_script_hash(@index, @source, CKB::Category::TYPE)
  end

  def read_lock_hash
    CKB.load_script_hash(i, CKB::Source::INPUT, CKB::Category::LOCK)
  end

  def read_status
    @status ||= CKB::CellField.new(@source, @index, CKB::CellField::DATA).read(8, 8).unpack("Q<")[0]
    case @status
    when 0
      :deposit
    when 1
      :withdraw
    else
      raise "unknown status"
    end
  end

  def verify_proof(proof)
    #NOTE empty implementation
    true
  end

  def verify_signature(signature)
    #NOTE empty implementation
    true
  end
end

# **deposit**
#
def verify_deposit!
  tx = CKB.load_tx
  # verify inputs
  # calculate udt count
  udt_count = 0
  # 1. inputs must have same type which equals to the udt_type_hash.
  # 2. inputs must not have lock script references to the contract_type_hash.
  tx["inputs"].size.times.each do |i|
    input_type_hash = CKB.load_script_hash(i, CKB::Source::INPUT, CKB::Category::TYPE)
    if input_type_hash != udt_type_hash
      raise "Inputs type must equals to udt_type_hash"
    end
    input_lock_hash = CKB.load_script_hash(i, CKB::Source::INPUT, CKB::Category::LOCK)
    if input_lock_hash == contract_type_hash
      raise "Inputs lock must not equals to this contract"
    end
    udt_count += UDT.new(CKB::Source::INPUT, i).read_token_count
  end
  udt_outputs = []
  ptoken_outputs = []
  # verify outputs
  # calculate ptoken count
  ptoken_count = 0
  deposit_udt_count = 0
  # 3. outputs must be either UDT which type is equals to the udt_type_hash, or PLASMA token which type is equals to this contract.
  # 4. PLASMA token in outputs must be deposit status.
  tx["outputs"].size.times.each do |i|
    output_type_hash = CKB.load_script_hash(i, CKB::Source::OUTPUT, CKB::Category::TYPE)
    if output_type_hash == udt_type_hash
      output_lock_hash = CKB.load_script_hash(i, CKB::Source::OUTPUT, CKB::Category::LOCK)
      if output_lock_hash != contract_type_hash(:withdraw)
        raise "Output lock must equals to this contract"
      end
      udt_outputs << i
      deposit_udt_count += UDT.new(CKB::Source::OUTPUT, i).read_token_count
    elsif output_type_hash == contract_type_hash(:deposit)
      c = PLASMAToken.new(CKB::Source::INPUT, i)
      if c.read_status != :deposit
        raise "deposit outputs must be deposit status"
      end
      ptoken_outputs << i
      ptoken_count += PLASMAToken.new(CKB::Source::OUTPUT, i).read_token_count
    end
  end

  # 5. inputs UDT count must equals to outputs UDT count equals to outputs PLASMA token count.
  if udt_count != ptoken_count
    raise "Must produce same count plasma token"
  end

  if udt_count != deposit_udt_count
    raise "Must produce same deposit udt"
  end
  true
end

# **start withdraw**
#
def verify_start_withdraw!
  tx = CKB.load_tx
  # verify inputs
  # calculate udt count
  input_ptoken_count = 0
  # inputs: must be plasma token
  tx["inputs"].size.times.each do |i|
    c = PLASMAToken.new(CKB::Source::INPUT, i)
    if c.read_type_hash != contract_type_hash(:deposit)
      raise "Inputs type must equals to contract_type_hash"
    end
    if c.read_status != :deposit
      raise "withdraw inputs must be deposit status"
    end
    input_ptoken_count += c.read_token_count
  end

  # verify outputs
  output_withdraw_ptoken_count = 0
  output_refund_ptoken_count = 0
  # output: 
  # 1. must be withdraw plasma token
  # 2. must locked by this contract
  # 3. start_withdraw_block_height == tx.valid_until
  tx["outputs"].size.times.each do |i|
    c = PLASMAToken.new(CKB::Source::OUTPUT, i)
    if c.read_type_hash != contract_type_hash(:withdraw)
      raise "Outputs type must equals to contract_type_hash"
    end
    if c.read_status == :withdraw
      output_withdraw_ptoken_count += c.read_token_count
    else
      output_refund_ptoken_count += c.read_token_count
    end
    # make sure lock_hash equals to this contract, so challenger can claim money
    if c.read_lock_hash != contract_type_hash(:withdraw)
      raise "Output lock must equals to this contract"
    end
  end

  if input_ptoken_count != (output_withdraw_ptoken_count + output_refund_ptoken_count)
    raise "Output withdraw token must equals input"
  end
  if output_withdraw_ptoken_count == 0
    raise "Must have non-zero withdraw token"
  end
  true
end

# **challenge**
# Need 1 inputs: plasma_token
# Need 1 extra ARGV: challenge proof
# How can challenger claim UDT to spent?
# * burn token to 0x0000 and issue new token?
# * use unlock script as a burn address then find a way to claim?
#     * unlock script only can unlock by this contract(how to do that?)
#     * deposit UTD output script must be this contract
#       * withdraw 可以花
#         * challenge 可以花
#       * 过了周期 && 依赖对应的 PLASMA token 来解锁(能花 plasma token 则本合约允许花对应的 UTD withdraw)
#       * 没过周期 && 能通过 challenge 条件则可以花 token
def verify_challenge!
  tx = CKB.load_tx
  # verify inputs
  # 1. input should be withdraw plasma token
  # 2. ARGV[2] should be a proof to challenge withdraw token
  if tx["inputs"].size != 1
    raise "challenge inputs size must be 1"
  end
  c = PLASMAToken.new(CKB::Source::INPUT, 0)
  if c.read_type_hash != contract_type_hash
    raise "Inputs type must equals to contract_type_hash"
  end
  if c.read_status != :withdraw
    raise "challenge inputs must be withdraw status"
  end
  withdraw_ptoken_count = c.read_token_count
  if !c.verify_proof(ARGV[2])
    raise "error proof, challenge failed"
  end
  # verify outputs
  # 1. should be a withdraw plasma token
  if tx["outputs"].size != 1
    raise "only support 1 outputs for now"
  end
  c = PLASMAToken.new(CKB::Source::OUTPUT, 0)
  if c.read_type_hash != contract_type_hash
    raise "Outputs type must equals to contract_type_hash"
  end
  if c.read_status != :withdraw
    raise "withdraw outputs must be withdraw status"
  end
  output_withdraw_ptoken_count = c.read_token_count

  if withdraw_ptoken_count != output_withdraw_ptoken_count
    raise "Output withdraw token must equals input"
  end
  true
end

# **withdraw**
# Need 2 inputs: plasma_token, deposited_UDT
# Need 1 extra ARGV: withdraw signature
# 3. all outputs must be UDT token which sum of UDT equals to first input UDT.
#
def verify_withdraw!
  tx = CKB.load_tx
  # verify inputs
  # 1. first input must be withdarw plasma token
  # 2. second input must be UDT which lock script references to this contract.
  if tx["inputs"].size != 2
    raise "challenge inputs size must be 2"
  end
  c = PLASMAToken.new(CKB::Source::INPUT, 0)
  if c.read_type_hash != contract_type_hash
    raise "Inputs type must equals to contract_type_hash"
  end
  if c.read_status != :withdraw
    raise "withdraw inputs must be withdraw status"
  end
  # 3. verify that challenge period is ended
  start_withdraw_block_height = CKB.load_block(tx["inputs"][0]["block_hash"])["height"]
  if start_withdraw_block_height + CHALLENGE_PERIOD >= tx["valid_since"]
    raise "can't withdraw, because challenge period is not end"
  end
  withdraw_ptoken_count = c.read_token_count
  # 4. verify signature to proof token ownership
  if !c.verify_signature(ARGV[2])
    raise "error signature, withdraw failed"
  end
  c = UDT.new(CKB::Source::INPUT, 1)
  if c.read_type_hash != udt_type_hash
    raise "Inputs type must equals to udt_type_hash"
  end
  if c.read_lock_hash != contract_type_hash
    raise "Inputs lock must equals to contract_type_hash"
  end
  withdraw_udt_count = c.read_token_count
  if withdraw_ptoken_count != withdraw_udt_count
    raise "PLASMAToken count must equals to UDT count"
  end
  # 5. verify chain congestion
  available_blocks = 0
  tx["block_deps"].each do |block_hash|
    block = Ckb.load_tx(block_hash)
    if block["height"] > start_withdraw_block_height && block["txs_cycles"] * 100 / BLOCK_MAX_CYCLES < 95
      available_blocks += 1
    end
  end
  if available_blocks < 50
    raise "must provide 50 blocks to proof chain congestion status"
  end
  # verify outputs
  if tx["outputs"].size != 1
    raise "only support 1 outputs for now"
  end
  c = UDT.new(CKB::Source::OUTPUT, 0)
  if c.read_type_hash != udt_type_hash
    raise "Outputs type must equals to udt_type_hash"
  end
  output_udt_count = c.read_token_count

  # withdraw token count is correct
  if withdraw_udt_count != output_udt_count
    raise "withdraw UDT must equals to input"
  end
  true
end

case token_status
when "deposit"
  verify_deposit!
when "start_withdraw"
  verify_start_withdraw!
when "challenge"
  verify_challenge!
when "withdraw"
  verify_withdraw!
else
  raise "token status error!"
end

