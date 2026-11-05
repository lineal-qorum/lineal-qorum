// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.2 <0.9.0;

import "../governance/LinealQorum.sol";

/**
 * @title PostBoard
 * @dev Tablero de publicaciones ("posts") respaldado por un mapa (mapping) on-chain,
 *      protegido por el sistema de quorum multi-nivel de LinealQorum
 *      (máquinas, instituciones, humanos) para las acciones sensibles
 *      (crear, editar, eliminar, moderar).
 *
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts
 */
contract PostBoard is LinealQorum {

    // ---------------------------------------------------------------------
    // Tipos de datos
    // ---------------------------------------------------------------------

    address private owner;

    // event for EVM logging
    event OwnerSet(address indexed oldOwner, address indexed newOwner);

    /**
     * @dev Return owner address
     * @return address of owner
     */

    /// @dev Estructura que representa un post individual
    struct Post {
        uint256 id;
        address author;
        string title;
        string content;
        string[] tags;
        uint256 createdAt;
        uint256 updatedAt;
        bool exists;
        bool isHidden;
        uint256 likeCount;
    }

    /// @dev Estructura para un comentario asociado a un post
    struct Comment {
        uint256 id;
        uint256 postId;
        address author;
        string content;
        uint256 createdAt;
        bool exists;
    }

    // ---------------------------------------------------------------------
    // Almacenamiento (el "mapa")
    // ---------------------------------------------------------------------

    /// @dev Mapa principal: id de post => Post
    mapping(uint256 => Post) private posts;

    /// @dev Mapa de comentarios: id de comentario => Comment
    mapping(uint256 => Comment) private comments;

    /// @dev Mapa de comentarios por post: postId => arreglo de commentIds
    mapping(uint256 => uint256[]) private postComments;

    /// @dev Mapa de posts por autor: address => arreglo de postIds
    mapping(address => uint256[]) private postsByAuthor;

    /// @dev Mapa de "me gusta" para evitar likes duplicados: postId => (address => bool)
    mapping(uint256 => mapping(address => bool)) private hasLiked;

    /// @dev Lista de todos los ids de post existentes (para enumeración)
    uint256[] private allPostIds;

    /// @dev Contadores incrementales
    uint256 private nextPostId;
    uint256 private nextCommentId;

    // ---------------------------------------------------------------------
    // Eventos
    // ---------------------------------------------------------------------

    event PostCreated(uint256 indexed id, address indexed author, string title, uint256 timestamp);
    event PostUpdated(uint256 indexed id, address indexed editor, uint256 timestamp);
    event PostDeleted(uint256 indexed id, address indexed remover, uint256 timestamp);
    event PostHiddenStatusChanged(uint256 indexed id, bool isHidden, address indexed moderator);
    event PostLiked(uint256 indexed id, address indexed liker, uint256 newLikeCount);
    event CommentAdded(uint256 indexed commentId, uint256 indexed postId, address indexed author);
    event CommentRemoved(uint256 indexed commentId, uint256 indexed postId, address indexed remover);

    // ---------------------------------------------------------------------
    // Errores personalizados
    // ---------------------------------------------------------------------

    error PostDoesNotExist(uint256 id);
    error CommentDoesNotExist(uint256 id);
    error NotPostAuthor(address caller, address author);
    error AlreadyLiked(address liker, uint256 postId);
    error EmptyTitleOrContent();
    error QuorumNotReached(bytes32 txHash, string action);

    // ---------------------------------------------------------------------
    // Modificadores
    // ---------------------------------------------------------------------

    modifier postExists(uint256 _id) {
        if (!posts[_id].exists) revert PostDoesNotExist(_id);
        _;
    }

    modifier commentExists(uint256 _id) {
        if (!comments[_id].exists) revert CommentDoesNotExist(_id);
        _;
    }

    modifier onlyPostAuthor(uint256 _id) {
        if (posts[_id].author != msg.sender) revert NotPostAuthor(msg.sender, posts[_id].author);
        _;
    }

    // modifier to check if caller is owner
    modifier isOwner() {
        // If the first argument of 'require' evaluates to 'false', execution terminates and all
        // changes to the state and to Ether balances are reverted.
        // This used to consume all gas in old EVM versions, but not anymore.
        // It is often a good idea to use 'require' to check if functions are called correctly.
        // As a second argument, you can also provide an explanation about what went wrong.
        require(msg.sender == owner, "Caller is not owner");
        _;
    }

    constructor(
        address _owner,
        address[] memory _machines,
        uint256 _requiredMachines,
        address[] memory _institutions,
        uint256 _requiredInstitutions,
        address[] memory _humans,
        uint256 _requiredHumans,
        uint256 _recoveryRequired
    ) LinealQorum(
    _machines,
    _requiredMachines,
    _institutions,
    _requiredInstitutions,
    _humans,
    _requiredHumans,
    _recoveryRequired
    ) {
        owner = _owner; // 'msg.sender' is sender of current call, contract deployer for a constructor
        emit OwnerSet(address(0), owner);
        nextPostId = 1;
        nextCommentId = 1;
    }

    // ---------------------------------------------------------------------
    // Creación y edición de posts (sin quorum: acción normal de usuario)
    // ---------------------------------------------------------------------

    /**
     * @notice Crea un nuevo post y lo guarda en el mapa.
     * @param _title Título del post.
     * @param _content Contenido del post.
     * @param _tags Etiquetas asociadas al post.
     * @return id El identificador del post recién creado.
     */
    function createPost(
        string calldata _title,
        string calldata _content,
        string[] calldata _tags
    ) external isOwner returns (uint256 id) {
        if (bytes(_title).length == 0 || bytes(_content).length == 0) {
            revert EmptyTitleOrContent();
        }

        id = nextPostId;
        nextPostId++;

        Post storage p = posts[id];
        p.id = id;
        p.author = msg.sender;
        p.title = _title;
        p.content = _content;
        p.createdAt = block.timestamp;
        p.updatedAt = block.timestamp;
        p.exists = true;
        p.isHidden = false;
        p.likeCount = 0;

        for (uint256 i = 0; i < _tags.length; i++) {
            p.tags.push(_tags[i]);
        }

        allPostIds.push(id);
        postsByAuthor[msg.sender].push(id);

        emit PostCreated(id, msg.sender, _title, block.timestamp);
    }

    /**
     * @notice Edita un post existente. Solo el autor puede editarlo directamente.
     */
    function editPost(
        uint256 _id,
        string calldata _newTitle,
        string calldata _newContent
    ) external isOwner postExists(_id) onlyPostAuthor(_id) {
        if (bytes(_newTitle).length == 0 || bytes(_newContent).length == 0) {
            revert EmptyTitleOrContent();
        }

        Post storage p = posts[_id];
        p.title = _newTitle;
        p.content = _newContent;
        p.updatedAt = block.timestamp;

        emit PostUpdated(_id, msg.sender, block.timestamp);
    }

    /**
     * @notice El propio autor elimina (lógicamente) su post.
     */
    function deleteOwnPost(uint256 _id) external isOwner postExists(_id) {
        _removePost(_id);
    }

    // ---------------------------------------------------------------------
    // Acciones sensibles protegidas por quorum (servidores / moderación)
    // ---------------------------------------------------------------------

    /**
     * @notice Elimina un post mediante confirmación de quorum de servidores,
     *         útil para moderación forzada cuando el autor no coopera.
     */
    function moderateDeletePost(uint256 _id) external onlyServers postExists(_id) {
        bytes32 txHash = _computeActionHash("moderateDeletePost", abi.encode(_id));
        if (!confirmServers(txHash, "moderateDeletePost")) {
            revert QuorumNotReached(txHash, "moderateDeletePost");
        }
        _removePost(_id);
    }


    /**
     * @notice Elimina un comentario mediante confirmación de quorum.
     */
    function moderateRemoveComment(uint256 _commentId) external onlyServers commentExists(_commentId) {
        bytes32 txHash = _computeActionHash("moderateRemoveComment", abi.encode(_commentId));
        if (!confirmServers(txHash, "moderateRemoveComment")) {
            revert QuorumNotReached(txHash, "moderateRemoveComment");
        }
        _removeComment(_commentId);
    }

    // ---------------------------------------------------------------------
    // Interacciones sociales: likes y comentarios
    // ---------------------------------------------------------------------

    /**
     * @notice Da "me gusta" a un post. Cada dirección solo puede dar like una vez.
     */
    function likePost(uint256 _id) external postExists(_id) {
        if (hasLiked[_id][msg.sender]) revert AlreadyLiked(msg.sender, _id);

        hasLiked[_id][msg.sender] = true;
        posts[_id].likeCount += 1;

        emit PostLiked(_id, msg.sender, posts[_id].likeCount);
    }

    /**
     * @notice Agrega un comentario a un post existente.
     */
    function addComment(uint256 _postId, string calldata _content)
    external
    postExists(_postId)
    returns (uint256 commentId)
    {
        if (bytes(_content).length == 0) revert EmptyTitleOrContent();

        commentId = nextCommentId;
        nextCommentId++;

        comments[commentId] = Comment({
            id: commentId,
            postId: _postId,
            author: msg.sender,
            content: _content,
            createdAt: block.timestamp,
            exists: true
        });

        postComments[_postId].push(commentId);

        emit CommentAdded(commentId, _postId, msg.sender);
    }

    /**
     * @notice El autor de un comentario puede eliminarlo directamente.
     */
    function removeOwnComment(uint256 _commentId) external commentExists(_commentId) {
        if (comments[_commentId].author != msg.sender) {
            revert NotPostAuthor(msg.sender, comments[_commentId].author);
        }
        _removeComment(_commentId);
    }

    // ---------------------------------------------------------------------
    // Funciones internas auxiliares
    // ---------------------------------------------------------------------

    function _removePost(uint256 _id) internal {
        posts[_id].exists = false;

        uint256[] storage ids = postComments[_id];
        for (uint256 i = 0; i < ids.length; i++) {
            comments[ids[i]].exists = false;
        }

        emit PostDeleted(_id, msg.sender, block.timestamp);
    }

    function _removeComment(uint256 _commentId) internal {
        uint256 postId = comments[_commentId].postId;
        comments[_commentId].exists = false;
        emit CommentRemoved(_commentId, postId, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Funciones de lectura (view)
    // ---------------------------------------------------------------------

    /// @notice Devuelve un post completo por id.
    function getPost(uint256 _id)
    external
    view
    postExists(_id)
    returns (
        uint256 id,
        address author,
        string memory title,
        string memory content,
        string[] memory tags,
        uint256 createdAt,
        uint256 updatedAt,
        bool isHidden,
        uint256 likeCount
    )
    {
        Post storage p = posts[_id];
        return (
            p.id,
            p.author,
            p.title,
            p.content,
            p.tags,
            p.createdAt,
            p.updatedAt,
            p.isHidden,
            p.likeCount
        );
    }

    /// @notice Devuelve los ids de todos los posts creados (incluidos los borrados lógicamente).
    function getAllPostIds() external view returns (uint256[] memory) {
        return allPostIds;
    }

    /// @notice Devuelve los ids de los posts creados por un autor específico.
    function getPostsByAuthor(address _author) external view returns (uint256[] memory) {
        return postsByAuthor[_author];
    }

    /// @notice Devuelve los ids de los comentarios de un post.
    function getCommentIdsForPost(uint256 _postId) external view postExists(_postId) returns (uint256[] memory) {
        return postComments[_postId];
    }

    /// @notice Devuelve el detalle de un comentario.
    function getComment(uint256 _commentId)
    external
    view
    commentExists(_commentId)
    returns (
        uint256 id,
        uint256 postId,
        address author,
        string memory content,
        uint256 createdAt
    )
    {
        Comment storage c = comments[_commentId];
        return (c.id, c.postId, c.author, c.content, c.createdAt);
    }

    /// @notice Devuelve una página de posts, útil para no traer todo el mapa de una vez.
    function getPostsPaginated(uint256 _offset, uint256 _limit)
    external
    view
    returns (Post[] memory page)
    {
        uint256 total = allPostIds.length;
        if (_offset >= total) {
            return new Post[](0);
        }

        uint256 end = _offset + _limit;
        if (end > total) {
            end = total;
        }

        page = new Post[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            page[i - _offset] = posts[allPostIds[i]];
        }
        return page;
    }

    /// @notice Indica si una dirección ya dio like a un post.
    function didLike(uint256 _postId, address _user) external view returns (bool) {
        return hasLiked[_postId][_user];
    }

    /// @notice Devuelve el número total de posts creados (incluye eliminados lógicamente).
    function totalPostsCreated() external view returns (uint256) {
        return nextPostId - 1;
    }

    /// @notice Devuelve el número total de comentarios creados.
    function totalCommentsCreated() external view returns (uint256) {
        return nextCommentId - 1;
    }

    function getOwner() external view returns (address) {
        return owner;
    }
}
