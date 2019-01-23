module Ckb
  class PLASMAToken
    attr_reader :amount, :status, :capacity, :lock_hash
    def initialize(amount, status)
      @amount = amount
      @status = status
    end
  end

  class PLASMATokenAccount
    CONTRACT_SCRIPT = File.read(File.expand_path("./contract.rb", File.dirname(__FILE__)))
    DEPOSIT_STATUS = 0
    WITHDRAW_STATUS = 1

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

    def unlock_type_hash
      Ckb::Utils.json_script_to_type_hash(edt_wallet.token_info.unlock_script_json_object(pubkey))
    end

    def deposit(udt_amount,
                output_plasma_account_capacity:,
                output_udt_capacity:,
                refund_udt_capacity:)
      generated_token = PLASMAToken.new(udt_amount, :deposit)
      # composit request
      inputs = gather_udt_inputs(udt_amount,
                                 refund_capacity: refund_udt_capacity, 
                                 reserve_capacity: output_plasma_account_capacity + output_udt_capacity)
      outputs = []
      # plasma account cell
      outputs << {
        capacity: output_plasma_account_capacity,
        data: [udt_amount, DEPOSIT_STATUS].pack("Q<2"),
        lock: unlock_type_hash,
        type: contract_script_json_object(status: :deposit)
      }
      # deposited UDT account cell
      # NOTICE we use contract_type_hash as output lock
      outputs << {
        capacity: output_udt_capacity,
        data: [udt_amount].pack("Q<"),
        lock: contract_type_hash,
        type: udt_wallet.token_info.contract_script_json_object
      }
      if i.amounts > udt_amount
        # output udt refund
        outputs << {
          capacity: refund_capacity,
          data: [i.amounts - udt_amount].pack("Q<"),
          lock: udt_wallet.address,
          type: udt_wallet.token_info.contract_script_json_object
        }
      end
      tx = {
        version: 0,
        deps: [],
        inputs: inputs,
        outputs: outputs
      }
      p "send", tx
      # send request
      api.send_transaction(tx)
    end

    def start_withdraw
    end

    def challenge
    end

    def withdraw
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
        input_amounts += cell[:data].unpack("Q<")[0]
        break if input_amounts >= udt_amount
      end
      raise "Not enough UDT amount!" if input_amounts < amount
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
      filter_unspent_cells do |cell|
        cell[:lock] == unlock_type_hash && cell[:type] == udt_type_hash
      end
    end

    def get_unspent_cells
      filter_unspent_cells do |cell|
        cell[:lock] == unlock_type_hash && cell[:type].nil?
      end
    end

    def filter_unspent_cells(&blk)
      to = api.get_tip_number
      results = []
      current_from = 1
      step = 100
      ((to - 1) / step + 1).times do
        current_to = [current_from + step, to].min
        cells = api.get_cells_by_type_hash(unlock_type_hash, current_from, current_to)
        cells = cells.select(&blk)
        results += cells
      end
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

