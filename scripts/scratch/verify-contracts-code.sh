#!/bin/bash
set -e
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )


if [[ -z "$NETWORK" ]]; then
    echo "Must set NETWORK env variable" 1>&2
    exit 1
fi

function jsonGet {
    node -e "const fs = require('fs'); const obj = JSON.parse(fs.readFileSync('deployed-${NETWORK}.json', 'utf8')); const path='$1'; let res = path.split('.').reduce(function(o, k) {return o && o[k] }, obj);  console.log(res)"
}

function jsonGetArray {
    node -e "const fs = require('fs'); const obj = JSON.parse(fs.readFileSync('deployed-${NETWORK}.json', 'utf8')); const path='$1'; let res = path.split('.').reduce(function(o, k) {return o && o[k] }, obj);  console.log(res.join(' '))"
}

function verify {
    contractPath="$(jsonGet ${1}.contract)"
    contractName="${contractPath##*/}"
    contractName="${contractName%.*}"
    echo "module.exports = $(jsonGet ${1}.constructorArgs)" > contract-args.js
    yarn hardhat --network $NETWORK verify --no-compile --contract "$contractPath:$contractName" --constructor-args contract-args.js $(jsonGet ${1}.address)
}

# verify dummyEmptyContract
# verify burner
# verify hashConsensusForAccounting
# verify hashConsensusForValidatorsExitBus
# verify accountingOracle.implementation
# verify accountingOracle.proxy
# verify validatorsExitBusOracle.implementation
# verify validatorsExitBusOracle.proxy
# verify stakingRouter.implementation
# verify stakingRouter.proxy
# verify withdrawalQueueERC721.proxy
# verify wstETH
# verify executionLayerRewardsVault
# verify eip712StETH
# verify lidoTemplate
# verify withdrawalVault.proxy
# verify withdrawalVault.implementation
# verify lidoLocator.proxy
# verify lidoLocator.implementation
# verify app:lido.implementation
# verify app:oracle.implementation
# verify app:node-operators-registry.implementation
# verify app:aragon-voting.implementation
# verify app:aragon-token-manager.implementation
# verify app:aragon-finance.implementation
# verify app:aragon-agent.implementation
# verify oracleDaemonConfig
# verify oracleReportSanityChecker

# verify withdrawalQueueERC721.implementation

# TODO: fix this verifications
verify ldo
# verify app:aragon-token-manager.proxy
# verify app:lido.proxy
# verify app:oracle.proxy
# verify app:node-operators-registry.proxy
# verify app:aragon-voting.proxy
# verify app:aragon-finance.proxy
# verify app:aragon-agent.proxy
# verify lidoApmAddress
