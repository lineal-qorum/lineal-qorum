// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title LinealTenders - NeoQuor
 * @notice Licitaciones como NFT. Cada licitación es un token (soulbound, en custodia de la
 * Institución) con título, descripción, imagen, URL del documento y su subcuenta en el banco.
 * Solo el owner (la Institución) puede emitirlas y modificarlas.
 */
contract LinealTender is ERC721, Ownable {

    uint256 public constant MAX_TITLE_LENGTH = 100; // bytes

    // Institución dueña de este contrato
    address public immutable institutionAddress;

    uint256 public tenderCounter;

    struct Tender {
        uint256 tokenId;
        string title;
        string description;
        string imageURI;
        string documentURL;
        uint256 amount;        // Monto de la licitación
        uint256 createdAt;
        bool active;
        bytes32 subAccountId;  // Subcuenta del banco asociada a la licitación
    }

    mapping(uint256 => Tender) private tenders;

    event TenderMinted(
        uint256 indexed tokenId,
        string title,
        string description,
        string imageURI,
        string documentURL,
        uint256 amount,
        bytes32 subAccountId
    );
    event TenderUpdated(
        uint256 indexed tokenId,
        string title,
        string description,
        string imageURI,
        string documentURL,
        uint256 amount
    );
    event TenderStatusChanged(uint256 indexed tokenId, bool active);

    error InvalidAddress();
    error EmptyTitle();
    error TitleTooLong();
    error EmptyDescription();
    error EmptyImageURI();
    error EmptyDocumentURL();
    error TenderDoesNotExist();
    error NonTransferable();
    error InvalidAmount();
    error InvalidSubAccount();

    /// @param _name               Nombre de la colección.
    /// @param _symbol             Símbolo de la colección.
    /// @param _institutionAddress Dueño del contrato (la Institución). Recibe los NFT.
    constructor(
        string memory _name,
        string memory _symbol,
        address _institutionAddress
    )
    ERC721(_name, _symbol)
    Ownable(_institutionAddress)
    {
        if (_institutionAddress == address(0)) revert InvalidAddress();
        institutionAddress = _institutionAddress;
    }

    /**
     * @notice Emite una licitación como NFT a la Institución (solo owner).
     * @param _title         Título (máx. 100 bytes).
     * @param _description   Descripción.
     * @param _imageURI      URL de la foto/imagen.
     * @param _documentURL   URL del documento de la licitación.
     * @param _amount        Monto de la licitación.
     * @param _subAccountId  Subcuenta del banco creada previamente por la Institución.
     */
    function mintTender(
        string calldata _title,
        string calldata _description,
        string calldata _imageURI,
        string calldata _documentURL,
        uint256 _amount,
        bytes32 _subAccountId
    ) external onlyOwner returns (uint256 tokenId) {
        _validate(_title, _description, _imageURI, _documentURL);

        if (_amount == 0) revert InvalidAmount();
        if (_subAccountId == bytes32(0)) revert InvalidSubAccount();

        tokenId = ++tenderCounter;

        tenders[tokenId] = Tender({
            tokenId: tokenId,
            title: _title,
            description: _description,
            imageURI: _imageURI,
            documentURL: _documentURL,
            amount: _amount,
            createdAt: block.timestamp,
            active: true,
            subAccountId: _subAccountId
        });

        _mint(institutionAddress, tokenId);

        emit TenderMinted(
            tokenId,
            _title,
            _description,
            _imageURI,
            _documentURL,
            _amount,
            _subAccountId
        );
    }

    /// @notice Actualiza los datos de una licitación existente (solo owner). La subcuenta no cambia.
    function updateTender(
        uint256 tokenId,
        string calldata _title,
        string calldata _description,
        string calldata _imageURI,
        string calldata _documentURL,
        uint256 amount
    ) external onlyOwner {
        if (_ownerOf(tokenId) == address(0)) revert TenderDoesNotExist();
        _validate(_title, _description, _imageURI, _documentURL);
        if (amount == 0) revert InvalidAmount();

        Tender storage t = tenders[tokenId];
        t.title = _title;
        t.description = _description;
        t.imageURI = _imageURI;
        t.documentURL = _documentURL;
        t.amount = amount;

        emit TenderUpdated(tokenId, _title, _description, _imageURI, _documentURL, amount);
    }

    /// @notice Abre o cierra una licitación (solo owner).
    function setTenderActive(uint256 tokenId, bool active) external onlyOwner {
        if (_ownerOf(tokenId) == address(0)) revert TenderDoesNotExist();
        tenders[tokenId].active = active;
        emit TenderStatusChanged(tokenId, active);
    }

    // --- LECTURA ---

    function getTender(uint256 tokenId) external view returns (Tender memory) {
        if (_ownerOf(tokenId) == address(0)) revert TenderDoesNotExist();
        return tenders[tokenId];
    }

    function getTenderCounter() external view returns (uint256) {
        return tenderCounter;
    }

    /// @notice Subcuenta del banco asociada a una licitación.
    function subAccountOf(uint256 tokenId) external view returns (bytes32) {
        if (_ownerOf(tokenId) == address(0)) revert TenderDoesNotExist();
        return tenders[tokenId].subAccountId;
    }

    /// @notice Lista todos los ids de licitaciones emitidas (1..tenderCounter).
    function getTenderIds() external view returns (uint256[] memory ids) {
        uint256 total = tenderCounter;
        ids = new uint256[](total);
        for (uint256 i = 0; i < total; i++) {
            ids[i] = i + 1;
        }
    }

    /// @notice Lista paginada de licitaciones completas (para evitar quedarse sin gas en lecturas grandes).
    /// @param offset Posición inicial (0 = primera licitación).
    /// @param limit  Máximo de resultados a devolver.
    function getTenders(uint256 offset, uint256 limit) external view returns (Tender[] memory page) {
        uint256 total = tenderCounter;
        if (offset >= total) return new Tender[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new Tender[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = tenders[i + 1];
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert TenderDoesNotExist();

        Tender storage t = tenders[tokenId];

        string memory json = Base64.encode(
            bytes(
                string.concat(
                    '{"name":"', _escape(t.title), '",',
                    '"description":"', _escape(t.description), '",',
                    '"image":"', _escape(t.imageURI), '",',
                    '"external_url":"', _escape(t.documentURL), '",',
                    _attributes(t),
                    '}'
                )
            )
        );

        return string.concat("data:application/json;base64,", json);
    }

    // --- INTERNAS ---

    function _attributes(Tender storage t) internal view returns (string memory) {
        return string.concat(
            '"attributes":[',
            '{"trait_type":"Institution","value":"', Strings.toHexString(institutionAddress), '"},',
            '{"trait_type":"Status","value":"', t.active ? "Active" : "Closed", '"},',
            '{"trait_type":"Account","value":"', Strings.toHexString(uint256(t.subAccountId), 32), '"},',
            '{"display_type":"date","trait_type":"Created","value":', Strings.toString(t.createdAt), '}',
            ']'
        );
    }

    /// @dev Soulbound: se puede mintear, pero no transferir entre wallets.
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert NonTransferable();
        return super._update(to, tokenId, auth);
    }

    function _validate(
        string calldata _title,
        string calldata _description,
        string calldata _imageURI,
        string calldata _documentURL
    ) internal pure {
        uint256 len = bytes(_title).length;
        if (len == 0) revert EmptyTitle();
        if (len > MAX_TITLE_LENGTH) revert TitleTooLong();
        if (bytes(_description).length == 0) revert EmptyDescription();
        if (bytes(_imageURI).length == 0) revert EmptyImageURI();
        if (bytes(_documentURL).length == 0) revert EmptyDocumentURL();
    }

    /// @dev Escapa comillas, backslash y saltos de línea para no romper el JSON del tokenURI.
    function _escape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length * 2);
        uint256 j;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == 0x22 || c == 0x5c) {            // " o \
                out[j++] = 0x5c;
                out[j++] = c;
            } else if (c == 0x0a) {                  // \n
                out[j++] = 0x5c;
                out[j++] = 0x6e;
            } else if (c == 0x0d || c == 0x09) {     // \r, \t -> espacio
                out[j++] = 0x20;
            } else {
                out[j++] = c;
            }
        }
        bytes memory trimmed = new bytes(j);
        for (uint256 k = 0; k < j; k++) {
            trimmed[k] = out[k];
        }
        return string(trimmed);
    }
}