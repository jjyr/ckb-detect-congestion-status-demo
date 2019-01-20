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
CHALLENGE_PERIOD = 100

# arguments
def udt_type_hash
  ARGV[0]
end

def token_status
  ARGV[1]
end

# PLASMA token should be this type
def contract_type_hash
  $contract_type_hash ||= CKB.load_script_hash(0, CKB::Source::CURRENT, CKB::Category::TYPE)
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

  def read_start_withdraw_block_height
    @start_withdraw_block_height ||= CKB::CellField.new(@source, @index, CKB::CellField::DATA).read(16, 8).unpack("Q<")[0]
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

# **deposit** must following below verify conditions:
# 1. outputs must be either UDT which type is equals to the udt_type_hash, or PLASMA token which type is equals to this contract.
# 2. all inputs must have same type which equals to the udt_type_hash.
# 3. all inputs must not have lock script references to the udt_type_hash.
# 4. inputs UDT count must equals to outputs UDT count equals to outputs PLASMA token count.
# 5. PLASMA token in outputs must be deposit status.
#
def verify_deposit!
  tx = CKB.load_tx
  # verify inputs
  # calculate udt count
  udt_count = 0
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
  tx["outputs"].size.times.each do |i|
    output_type_hash = CKB.load_script_hash(i, CKB::Source::OUTPUT, CKB::Category::TYPE)
    if output_type_hash == udt_type_hash
      output_lock_hash = CKB.load_script_hash(i, CKB::Source::OUTPUT, CKB::Category::LOCK)
      if output_lock_hash != contract_type_hash
        raise "Output lock must equals to this contract"
      end
      udt_outputs << i
      deposit_udt_count += UDT.new(CKB::Source::OUTPUT, i).read_token_count
    elsif output_type_hash == contract_type_hash
      verify_plasma_token_status!(CKB::Source::OUTPUT, i, :deposit)
      ptoken_outputs << i
      ptoken_count += PLASMAToken.new(CKB::Source::OUTPUT, i).read_token_count
    else
      raise "Output type must be equals to udt or this contract"
    end
  end

  if udt_count != ptoken_count
    raise "Must produce same count plasma token"
  end

  if udt_count != deposit_udt_count
    raise "Must produce same deposit udt"
  end
  true
end

# **start withdraw**
# 1. type of inputs tokens and outputs tokens must equals to this contract.
# 2. all inputs tokens is under deposit status, all outputs tokens is under withdraw status.
# 3. start_withdraw_at_block of outputs PLASMA token must be greater than parent block number
#
def verify_start_withdraw!
  tx = CKB.load_tx
  # verify inputs
  # calculate udt count
  withdraw_ptoken_count = 0
  tx["inputs"].size.times.each do |i|
    c = PLASMAToken.new(CKB::Source::INPUT, i)
    if c.read_type_hash != contract_type_hash
      raise "Inputs type must equals to contract_type_hash"
    end
    if c.read_status != :deposit
      raise "withdraw inputs must be deposit status"
    end
    withdraw_ptoken_count += c.read_token_count
  end
  # verify outputs
  # calculate ptoken count
  if tx["outputs"].size != 1
    raise "only support 1 outputs for now"
  end
  output_withdraw_ptoken_count = 0
  tx["outputs"].size.times.each do |i|
    c = PLASMAToken.new(CKB::Source::OUTPUT, i)
    if c.read_type_hash != contract_type_hash
      raise "Outputs type must equals to contract_type_hash"
    end
    if c.read_status != :withdraw
      raise "withdraw outputs must be withdraw status"
    end
    # make sure lock_hash equals to this contract, so challenger can claim money
    if c.read_lock_hash != contract_type_hash
      raise "Output lock must equals to this contract"
    end
    if c.read_start_withdraw_block_height < current_block_height
      raise "start_withdraw_block_height must great or equal than current block height"
    end
    output_withdraw_ptoken_count += c.read_token_count
  end

  if withdraw_ptoken_count != output_withdraw_ptoken_count
    raise "Output withdraw token must equals input"
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
  # calculate udt count
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
  if c.read_start_withdraw_block_height + CHALLENGE_PERIOD < current_block_height
    raise "can't challenge withdraw, because challenge period is end"
  end
  withdraw_ptoken_count = c.read_token_count
  if !c.verify_proof(ARGV[2])
    raise "error proof, challenge failed"
  end
  # verify outputs
  # calculate ptoken count
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
  if c.read_start_withdraw_block_height < current_block_height
    raise "start_withdraw_block_height must great or equal than current block height"
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
# 1. first input must be UDT which lock script references to this contract.
# 2. other inputs must be PLASMA token(issued from this contract) which status is withdraw and challenge_period is end, and sum of token should equals to first input UDT.
# 3. all outputs must be UDT token which sum of UDT equals to first input UDT.
#
def verify_withdraw!
  tx = CKB.load_tx
  # verify inputs
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
  if c.read_start_withdraw_block_height + CHALLENGE_PERIOD >= current_block_height
    raise "can't withdraw, because challenge period is not end"
  end
  withdraw_ptoken_count = c.read_token_count
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
  # verify outputs
  # calculate ptoken count
  if tx["outputs"].size != 1
    raise "only support 1 outputs for now"
  end
  c = UDT.new(CKB::Source::OUTPUT, 0)
  if c.read_type_hash != udt_type_hash
    raise "Outputs type must equals to udt_type_hash"
  end
  output_udt_count = c.read_token_count

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

