###
# 1. 每个 Cell 都有 type 我理解是类似 schema 之类的, 
# 但现在它在做两件事: 1. schema 检查 Cell 格式 2. 验证合约逻辑
# 后者已经是 tx 层的事情(检查多个 inputs outputs 规则)，这里的概念设计有些不清晰
#
# 2. PLASMA 抵押/dispute 类操作会占用 lock，这样当抵押后用户就无法用更多样的形式去 unlock 了，
# 这样是一个弊端无法做到解耦，比如用户 perfer multi-sig, 但这时只能靠 PLASMA 合约的设计者去支持
#
# 3. valid_since/valid_until 是否改为 timestamp 在 CKB 共识下会更合理
#
#
# tx:
# valid_since
# valid_until
# cell/block_hash
# block_hash_list

module Ckb
  class PLASMATokenAccount
    CONTRACT_SCRIPT = File.read(File.expand_path("./contract.rb", File.dirname(__FILE__)))
    DEPOSIT_STATUS = 0
    WITHDRAW_STATUS = 1
    UDT_CAPACITY=10
    PLASMA_TOKEN_ACCOUNT_CAPACITY=20

    CHALLENGE_PERIOD = 10

    attr_reader :api, :udt_wallet

    def initialize(api:, udt_wallet:)
      @api = api
      @udt_wallet = udt_wallet
    end

    def udt_type_hash
      udt_wallet.contract_type_hash
    end

    def pubkey
      udt_wallet.pubkey
    end

    def udt_lock_hash
      Ckb::Utils.json_script_to_type_hash(udt_wallet.token_info.unlock_script_json_object(pubkey))
    end

    def ckb_address
      udt_wallet.wallet.address
    end

    def deposit(udt_amount,
                output_plasma_account_capacity:
               )
      # input1: UDT input
      gathered_input = gather_udt_inputs(udt_amount,
                                 refund_capacity: refund_udt_capacity, 
                                 reserve_capacity: output_plasma_account_capacity + output_udt_capacity)
      outputs = []
      refund_capacities = gathered_input.capacities - PLASMA_TOKEN_ACCOUNT_CAPACITY - UDT_CAPACITY
      # output1: plasma account cell
      outputs << {
        capacity: PLASMA_TOKEN_ACCOUNT_CAPACITY,
        data: [udt_amount, DEPOSIT_STATUS].pack("Q<2"),
        lock: udt_lock_hash,
        type: contract_script_json_object(status: :deposit)
      }
      # output2: deposited UDT account cell
      # NOTICE lock address changed
      outputs << {
        capacity: UDT_CAPACITY,
        data: [udt_amount].pack("Q<"),
        lock: Ckb::Utils.json_script_to_type_hash(contract_script_json_object(status: :withdraw)),
        type: udt_wallet.token_info.contract_script_json_object
      }
      if gathered_input.amounts > udt_amount
        refund_capacities -= UDT_CAPACITY
        # output3: udt refund
        outputs << {
          capacity: UDT_CAPACITY,
          data: [gathered_input.amounts - udt_amount].pack("Q<"),
          lock: udt_wallet.address,
          type: udt_wallet.token_info.contract_script_json_object
        }
      end
      # output4: refund capacities
      if refund_capacities > 0
        outputs << {
          capacity: refund_capacities,
          data: "",
          lock: ckb_address,
          type: "",
        }
      end
      tx = {
        version: 0,
        deps: [],
        inputs: gathered_input.inputs,
        outputs: outputs
      }
      p "send", tx
      # send request
      api.send_transaction(tx)
    end

    def start_withdraw(amount,
                       output_lock_hash:,
                       output_withdraw_plasma_token_capacity:,
                      refund_plasma_token_capacity:)
      # input1: wrapped plasma token
      gathered_input = gather_plasma_token_inputs(amount,
                                      status: DEPOSIT_STATUS,
                                      refund_capacity: refund_plasma_token_capacity, 
                                      reserve_capacity: output_withdraw_plasma_token_capacity + output_signature_capacity)
      outputs = []
      refund_capacities = gathered_input.capacities - output_withdraw_plasma_token_capacity - output_signature_capacity
      # output1 withdrawable plasma token
      outputs << {
        capacity: output_withdraw_plasma_token_capacity,
        data: [amount, WITHDRAW_STATUS, output_lock_hash].pack("Q<3"),
        lock: Ckb::Utils.json_script_to_type_hash(contract_script_json_object(status: :withdraw)),
        type: contract_script_json_object(status: :withdraw)
      }
      if gathered_input.amounts > amount
        refund_capacities -= refund_plasma_token_capacity
        # output2 refund deposited plasma token
        outputs << {
          capacity: refund_plasma_token_capacity,
          data: [gathered_input.amounts - amount, DEPOSIT_STATUS].pack("Q<2"),
          lock: udt_lock_hash,
          type: contract_script_json_object(status: :deposit)
        }
      end
      # refund capacities
      if refund_capacities > 0
        outputs << {
          capacity: refund_capacities,
          data: "",
          lock: ckb_address,
          type: "",
        }
      end
      tx = {
        version: 0,
        deps: [],
        inputs: gathered_input.inputs,
        outputs: outputs,
      }
      p "send", tx
      # send request
      api.send_transaction(tx)
    end

    def challenge
    end

    def withdraw(amount,
                 start_withdraw_block_height:)
      # input1: withdraw PLASMA token
      ptoken_gathered_input = gather_plasma_token_inputs(amount,
                                      status: WITHDRAW_STATUS,
                                      refund_capacity: 0, 
                                      )
      if ptoken_gathered_input.amounts != amount
        raise "can't find a withdrawing plasma token with amount #{amount}"
      end
      # input2: deposited(locked) UDT
      udt_gathered_input = gather_udt_inputs(amount, refund_capacity: 0)
      if udt_gathered_input.amounts != amount
        raise "can't find a deposited udt token with amount #{amount}"
      end
      outputs = []
      refund_capacities = ptoken_gathered_input.capacities + udt_gathered_input
      # output1 udt
      outputs << {
        capacity: refund_capacities,
        data: [amount].pack("Q<"),
        lock: udt_lock_hash,
        type: udt_type_hash
      }
      # tx
      start_withdraw_block_hash = api.get_block_hash(start_withdraw_block_height)
      ptoken_gathered_input.inputs[0].merge!(block_hash: start_withdraw_block_hash)
      tx = {
        version: 0,
        deps: [],
        inputs: ptoken_gathered_input.inputs + udt_gathered_input.inputs,
        outputs: outputs,
        valid_since: start_withdraw_block_height + CHALLENGE_PERIOD + 1,
        block_deps: available_blocks,
      }
      p "send", tx
      # send request
      api.send_transaction(tx)
    end

    private

    def gather_udt_inputs(udt_amount,
                          refund_capacity:,
                          reserve_capacity:)
      input_capacities = 0
      input_amounts = 0
      inputs = []
      get_unspent_udt_cells.each do |cell|
        input = {
          previous_output: {
            hash: cell[:out_point][:hash],
            index: cell[:out_point][:index]
          },
          unlock: udt_wallet.token_info.unlock_script_json_object(pubkey)
        }
        inputs << input
        input_capacities += cell[:capacity]
        input_amounts += cell[:output][:data].unpack("Q<")[0]
        break if input_amounts >= udt_amount
      end
      raise "Not enough UDT amount!" if input_amounts < udt_amount
      need_capacities = if input_amounts > udt_amount
                          reserve_capacity + refund_capacity
                        else
                          reserve_capacity
                        end
      if input_capacities < need_capacities
        get_unspent_cells.each do |cell|
          input = {
            previous_output: {
              hash: cell[:out_point][:hash],
              index: cell[:out_point][:index]
            },
            unlock: udt_wallet.token_info.unlock_script_json_object(pubkey)
          }
          inputs << input
          input_capacities += cell[:capacity]
          break if input_capacities >= need_capacities
        end
      end
      raise "Not enough capacity!" if input_capacities < need_capacities
      OpenStruct.new(inputs: inputs, amounts: input_amounts, capacities: input_capacities)
    end

    def get_unspent_udt_cells
      filter_unspent_cells(udt_lock_hash)
    end

    def get_unspent_cells
      filter_unspent_cells(ckb_address)
    end

    def filter_unspent_cells(lock_hash)
      to = api.get_tip_number
      results = []
      step = 100
      (to / step + 1).times do |i|
        current_from = i * step
        current_to = [current_from + step - 1, to].min
        cells = api.get_cells_by_type_hash(lock_hash, current_from, current_to)
        cells.each do |cell|
          tx = api.get_transaction(cell[:out_point][:hash])
          cell.merge!(output: tx[:outputs][cell[:out_point][:index]])
        end
        results += cells.to_a
      end
      results
    end

    def contract_script_json_object(status:)
      {
        version: 0,
        reference: api.mruby_cell_hash,
        signed_args: [
          CONTRACT_SCRIPT,
          udt_type_hash
        ],
        args: [status]
      }
    end
  end
end

