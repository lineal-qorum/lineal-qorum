// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

contract LinealDeployer {

    event Deployed(address addr);

    function deploy(
        bytes memory bytecode,
        bytes32 salt
    ) external returns (address addr) {

        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        emit Deployed(addr);
    }
}