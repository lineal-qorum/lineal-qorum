// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract LinealCitizens is ERC721, Ownable {
    using Strings for uint256;

    // ───────────── Constantes ─────────────

    uint256 public constant MAX_SCORE = 10000;
    uint256 public constant MIN_DELTA = 1;
    uint256 public constant MAX_DELTA = 10000;

    // ───────────── Identidad y reputación ─────────────

    uint256 public tokenCounter;

    // Permite encontrar el NFT de una wallet.
    mapping(address => uint256) public walletToToken;

    // Los nombres de usuario son únicos dentro de esta institución.
    mapping(string => bool) public usernameTaken;

    struct Profile {
        uint256 tokenId;
        string username;
        string imageURI;
        bytes32 subAccountId;
        uint256 reputation;
        bool exists;
    }

    // La identidad y su reputación pertenecen al mismo NFT.
    mapping(uint256 => Profile) private profiles;

    // Estadísticas agregadas de todos los perfiles.
    uint256 public totalGlobalScore;
    uint256 public totalWallets;

    // ───────────── Eventos ─────────────

    event ProfileIssued(
        address indexed wallet,
        uint256 indexed tokenId,
        string username,
        bytes32 subAccountId
    );

    event ProfileImageUpdated(
        address indexed wallet,
        string newImageURI
    );

    event ScoreUpdated(
        address indexed wallet,
        uint256 indexed tokenId,
        uint256 oldScore,
        uint256 newScore
    );

    // ───────────── Constructor ─────────────

    constructor(
        string memory identityName,
        string memory identitySymbol,
        address institutionOwner
    )
    ERC721(identityName, identitySymbol)
    Ownable(institutionOwner)
    {
        require(
            institutionOwner != address(0),
            "Invalid institution owner"
        );
    }

    // ───────────── Crear perfil NFT ─────────────

    function mintProfile(
        address wallet,
        string calldata username,
        string calldata imageURI,
        bytes32 subAccountId
    ) external onlyOwner returns (uint256) {
        require(wallet != address(0), "Invalid wallet");
        require(walletToToken[wallet] == 0, "Profile exists");
        require(bytes(username).length > 0, "Empty username");
        require(bytes(username).length <= 32, "Username too long");
        require(!usernameTaken[username], "Username taken");
        require(_validUsername(username), "Invalid username");
        require(_validImageURI(imageURI), "Invalid image URI");
        require(subAccountId != bytes32(0), "Invalid subaccount");

        tokenCounter++;
        uint256 tokenId = tokenCounter;

        usernameTaken[username] = true;
        walletToToken[wallet] = tokenId;

        profiles[tokenId] = Profile({
            tokenId: tokenId,
            username: username,
            imageURI: imageURI,
            subAccountId: subAccountId,
            reputation: 0,
            exists: true
        });

        // Cada NFT nuevo inicia con reputación cero.
        totalWallets++;

        _mint(wallet, tokenId);

        emit ProfileIssued(
            wallet,
            tokenId,
            username,
            subAccountId
        );

        return tokenId;
    }

    // ───────────── Actualizar imagen ─────────────

    function setImageURI(
        address wallet,
        string calldata newImageURI
    ) external onlyOwner {
        uint256 tokenId = walletToToken[wallet];

        require(tokenId != 0, "Profile not found");
        require(_validImageURI(newImageURI), "Invalid image URI");

        profiles[tokenId].imageURI = newImageURI;

        emit ProfileImageUpdated(wallet, newImageURI);
    }

    // ───────────── Consultar perfil ─────────────

    function getProfile(
        address wallet
    )
    external
    view
    returns (
        uint256 tokenId,
        string memory username,
        string memory imageURI,
        bytes32 subAccountId,
        uint256 reputation,
        string memory level
    )
    {
        tokenId = walletToToken[wallet];

        require(tokenId != 0, "Profile not found");

        Profile storage p = profiles[tokenId];

        return (
            p.tokenId,
            p.username,
            p.imageURI,
            p.subAccountId,
            p.reputation,
            _levelOf(p.reputation)
        );
    }

    function getProfileByToken(
        uint256 tokenId
    )
    external
    view
    returns (Profile memory profile, string memory level)
    {
        require(profiles[tokenId].exists, "Profile not found");

        profile = profiles[tokenId];
        level = _levelOf(profile.reputation);
    }

    function getTokenCounter() external view returns (uint256) {
        return tokenCounter;
    }

    // ───────────── Reputación del NFT ─────────────

    function updateScore(
        uint256 tokenId,
        uint256 delta,
        bool positive
    ) external onlyOwner {
        require(profiles[tokenId].exists, "Profile not found");
        require(
            delta >= MIN_DELTA && delta <= MAX_DELTA,
            "Invalid delta"
        );

        Profile storage p = profiles[tokenId];

        uint256 oldScore = p.reputation;
        uint256 newScore;

        if (positive) {
            // Evita desbordamiento y limita la reputación a 10000.
            if (delta >= MAX_SCORE - oldScore) {
                newScore = MAX_SCORE;
            } else {
                newScore = oldScore + delta;
            }
        } else {
            newScore = delta >= oldScore ? 0 : oldScore - delta;
        }

        p.reputation = newScore;

        totalGlobalScore =
            totalGlobalScore -
            oldScore +
            newScore;

        emit ScoreUpdated(
            ownerOf(tokenId),
            tokenId,
            oldScore,
            newScore
        );
    }

    function getReputation(
        uint256 tokenId
    )
    external
    view
    returns (
        uint256 overall,
        string memory level
    )
    {
        require(profiles[tokenId].exists, "Profile not found");

        overall = profiles[tokenId].reputation;
        level = _levelOf(overall);
    }

    function _levelOf(
        uint256 score
    ) internal view returns (string memory) {
        uint256 average = totalWallets == 0
            ? 0
            : totalGlobalScore / totalWallets;

        if (
            score >= 9500 ||
            (average > 0 && score >= average * 5)
        ) {
            return "Anomalia";
        }

        if (score >= 8000) return "Principal";
        if (score >= 6000) return "Agente";
        if (score >= 4000) return "Operador";
        if (score >= 2000) return "Jugador";

        return "Ciudadano";
    }

    // ───────────── NFT soulbound ─────────────

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Permite mintear, pero impide transferencias y quemados.
        if (from != address(0)) {
            revert("Identity is non-transferable");
        }

        return super._update(to, tokenId, auth);
    }

    // ───────────── Metadatos NFT ─────────────

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        require(profiles[tokenId].exists, "Token not found");

        Profile storage p = profiles[tokenId];

        string memory json = string.concat(
            '{"name":"',
            _escapeJSON(p.username),
            '","description":"Lineal Identity",',
            '"image":"',
            _escapeJSON(p.imageURI),
            '","attributes":[',
            '{"trait_type":"Institution","value":"',
            Strings.toHexString(uint160(owner()), 20),
            '"},',
            '{"trait_type":"Account","value":"',
            Strings.toHexString(uint256(p.subAccountId), 32),
            '"},',
            '{"trait_type":"Reputation","value":',
            Strings.toString(p.reputation),
            '},',
            '{"trait_type":"Level","value":"',
            _levelOf(p.reputation),
            '"}]}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }


    function subAccountOf(address wallet) external view returns (bytes32) {
        uint256 tokenId = walletToToken[wallet];
        if (tokenId == 0) return bytes32(0);
        return profiles[tokenId].subAccountId;
    }
    // ───────────── Validaciones ─────────────

    function _validUsername(
        string calldata username
    ) internal pure returns (bool) {
        bytes calldata b = bytes(username);

        for (uint256 i; i < b.length; i++) {
            bytes1 c = b[i];

            bool valid =
                (c >= 0x41 && c <= 0x5A) ||
                (c >= 0x61 && c <= 0x7A) ||
                (c >= 0x30 && c <= 0x39) ||
                c == 0x5F ||
                c == 0x2D ||
                c == 0x2E;

            if (!valid) return false;
        }

        return true;
    }

    function _validImageURI(
        string calldata uri
    ) internal pure returns (bool) {
        bytes calldata b = bytes(uri);

        if (b.length == 0) return false;

        for (uint256 i; i < b.length; i++) {
            uint8 c = uint8(b[i]);

            // Evita caracteres de control. El JSON se escapa aparte.
            if (c < 0x20 || c == 0x7F) return false;
        }

        return true;
    }

    function _escapeJSON(
        string memory value
    ) internal pure returns (string memory) {
        bytes memory input = bytes(value);
        bytes memory output = new bytes(input.length * 2);
        uint256 j;

        for (uint256 i; i < input.length; i++) {
            bytes1 c = input[i];

            if (c == 0x22 || c == 0x5C) {
                output[j++] = 0x5C;
                output[j++] = c;
            } else if (uint8(c) < 0x20) {
                // Los caracteres de control no son necesarios
                // en username ni imageURI.
                output[j++] = 0x20;
            } else {
                output[j++] = c;
            }
        }

        bytes memory result = new bytes(j);

        for (uint256 i; i < j; i++) {
            result[i] = output[i];
        }

        return string(result);
    }
}

/// @notice Low Life, High Tech - Todos los derechos reservados.