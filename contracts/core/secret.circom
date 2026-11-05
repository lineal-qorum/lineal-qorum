pragma circom 2.1.0;

include "circomlib/circuits/poseidon.circom";

template SecretVerifier() {
    signal input secret;           // privado: el secreto que genera tu app
    signal input txHash;           // público: vincula la prueba a la acción concreta
    signal input commitment;       // público: Poseidon(secret) registrado on-chain
    signal input contractAddress;  // público: address(this) - BLOQUE D domain separation
    signal input chainId;          // público: block.chainid - BLOQUE D domain separation
    signal input signerAddress;    // público: msg.sender - BLOQUE B binding

    signal output nullifier;       // público: Poseidon(secret, txHash, contract, chainId) — uso único

    // Verifica que el firmante conoce la preimagen del commitment
    component h1 = Poseidon(1);
    h1.inputs[0] <== secret;
    h1.out === commitment;

    // BLOQUE D: Computa nullifier con domain separation completa
    // nullifier = Poseidon(secret, txHash, contractAddress, chainId, signerAddress)
    // Imposible reutilizar en otra cadena, otro contrato, u otro signer
    component h2 = Poseidon(5);
    h2.inputs[0] <== secret;
    h2.inputs[1] <== txHash;
    h2.inputs[2] <== contractAddress;
    h2.inputs[3] <== chainId;
    h2.inputs[4] <== signerAddress;
    nullifier <== h2.out;
}

component main {public [commitment, txHash, contractAddress, chainId, signerAddress]} = SecretVerifier();

