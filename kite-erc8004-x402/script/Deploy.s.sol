// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC8004IdentityRegistry} from "../src/ERC8004IdentityRegistry.sol";
import {CognitionLicenseSKUs} from "../src/CognitionLicenseSKUs.sol";
import {X402SettlementUSDC} from "../src/X402SettlementUSDC.sol";

contract Deploy is Script {
    function run() external returns (
        ERC8004IdentityRegistry identity,
        CognitionLicenseSKUs skus,
        X402SettlementUSDC settlement
    ) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(0)));

        address usdc = _usdcForChain(block.chainid);
        if (usdc == address(0)) {
            usdc = vm.envAddress("USDC_ADDRESS");
        }
        require(usdc != address(0), "USDC address not set");

        vm.startBroadcast(deployerKey);
        identity = new ERC8004IdentityRegistry();
        skus = new CognitionLicenseSKUs();
        settlement = new X402SettlementUSDC(address(identity), address(skus), usdc, treasury, feeBps);
        vm.stopBroadcast();

        console2.log("ERC8004IdentityRegistry:", address(identity));
        console2.log("CognitionLicenseSKUs:", address(skus));
        console2.log("X402SettlementUSDC:", address(settlement));
    }

    function _usdcForChain(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) {
            return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // ETH Mainnet USDC
        }
        if (chainId == 56) {
            return 0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d; // BSC Mainnet USDC
        }
        if (chainId == 2368) {
            return address(0); // Kite Testnet: set via USDC_ADDRESS
        }
        return address(0);
    }
}
