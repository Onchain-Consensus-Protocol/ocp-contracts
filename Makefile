# 需在 solidity/.env 中设置:
#   PRIVATE_KEY=0x...       部署用私钥
#   ETHERSCAN_API_KEY=...   验证用 (Etherscan V2 统一 key: https://etherscan.io/apidashboard)

RPC_URL ?= https://sepolia.base.org
CHAIN_ID ?= 84532
# Etherscan API V2 统一端点，避免 BaseScan V1 弃用导致的 "expected value at line 1 column 1"
VERIFIER_URL ?= https://api.etherscan.io/v2/api?chainid=$(CHAIN_ID)
SCRIPT := script/Deploy.s.sol:DeployScript

.PHONY: deploy verify-factory verify-token verify-vault verify-market clean

# 部署 MockERC20 + OCPVaultFactory 到 Base Sepolia
deploy:
	@test -n "$$PRIVATE_KEY" || (echo "Set PRIVATE_KEY in env (e.g. source .env)"; exit 1)
	forge script $(SCRIPT) --rpc-url $(RPC_URL) --broadcast --verify --etherscan-api-key $$ETHERSCAN_API_KEY

# 验证已部署的 OCPVaultFactory（传入地址: make verify-factory ADDR=0x...）
verify-factory:
	@test -n "$$ETHERSCAN_API_KEY" || (echo "Set ETHERSCAN_API_KEY in env"; exit 1)
	@test -n "$(ADDR)" || (echo "Usage: make verify-factory ADDR=0x..."; exit 1)
	forge verify-contract $(ADDR) src/factory/OCPVaultFactory.sol:OCPVaultFactory \
		--verifier etherscan \
		--chain-id $(CHAIN_ID) \
		--verifier-url "$(VERIFIER_URL)" \
		--etherscan-api-key $$ETHERSCAN_API_KEY

# 验证已部署的 MockERC20（部署脚本里的合约，需用部署输出的地址）
verify-token:
	@test -n "$$ETHERSCAN_API_KEY" || (echo "Set ETHERSCAN_API_KEY in env"; exit 1)
	@test -n "$(ADDR)" || (echo "Usage: make verify-token ADDR=0x..."; exit 1)
	forge verify-contract $(ADDR) script/Deploy.s.sol:MockERC20 \
		--verifier etherscan \
		--chain-id $(CHAIN_ID) \
		--verifier-url "$(VERIFIER_URL)" \
		--etherscan-api-key $$ETHERSCAN_API_KEY

# 验证 OCPVault 单合约（由工厂创建的金库，按需使用）
verify-vault:
	@test -n "$$ETHERSCAN_API_KEY" || (echo "Set ETHERSCAN_API_KEY in env"; exit 1)
	@test -n "$(ADDR)" || (echo "Usage: make verify-vault ADDR=0x..."; exit 1)
	@code=$$(cast code $(ADDR) --rpc-url $(RPC_URL)); \
	[ "$$code" != "0x" ] || (echo "No contract code at $(ADDR)"; exit 1); \
	factory=$$(cast call $(ADDR) "factory()(address)" --rpc-url $(RPC_URL) | awk '{print $$1}'); \
	stake_token=$$(cast call $(ADDR) "stakeToken()(address)" --rpc-url $(RPC_URL) | awk '{print $$1}'); \
	resolution=$$(cast call $(ADDR) "resolutionTime()(uint256)" --rpc-url $(RPC_URL) | awk '{print $$1}'); \
	challenge_end=$$(cast call $(ADDR) "challengeWindowEnd()(uint256)" --rpc-url $(RPC_URL) | awk '{print $$1}'); \
	min_stake=$$(cast call $(ADDR) "minStake()(uint256)" --rpc-url $(RPC_URL) | awk '{print $$1}'); \
	challenge_seconds=$$((challenge_end - resolution)); \
	forge verify-contract $(ADDR) src/core/OCPVault.sol:OCPVault \
		--verifier etherscan \
		--chain-id $(CHAIN_ID) \
		--verifier-url "$(VERIFIER_URL)" \
		--etherscan-api-key $$ETHERSCAN_API_KEY \
		--constructor-args $$(cast abi-encode "constructor(address,address,uint256,uint256,uint256)" $$factory $$stake_token $$resolution $$challenge_seconds $$min_stake)

# 验证 PredictionMarket（由工厂创建的市场，每个金库对应一个 market 地址）
verify-market:
	@test -n "$$ETHERSCAN_API_KEY" || (echo "Set ETHERSCAN_API_KEY in env"; exit 1)
	@test -n "$(ADDR)" || (echo "Usage: make verify-market ADDR=0x..."; exit 1)
	forge verify-contract $(ADDR) src/market/PredictionMarket.sol:PredictionMarket \
		--verifier etherscan \
		--chain-id $(CHAIN_ID) \
		--verifier-url "$(VERIFIER_URL)" \
		--etherscan-api-key $$ETHERSCAN_API_KEY

# 用法示例:
#   make deploy
#   make verify-factory ADDR=0x794D87e33Eb83Dd6f735f76F8Cd551C2901B9b8D
#   make verify-token   ADDR=0xe343be8F1d8572937da49234882e6a1eF4FFEb26
#   make verify-vault   ADDR=0x...   # 工厂创建的金库地址
#   make verify-market  ADDR=0x...   # 工厂创建的市场地址

clean:
	forge clean
