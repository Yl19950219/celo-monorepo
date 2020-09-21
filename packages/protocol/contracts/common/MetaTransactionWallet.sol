pragma solidity ^0.5.13;
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";

import "./interfaces/ICeloVersionedContract.sol";
import "./interfaces/IMetaTransactionWallet.sol";
import "./ExternalCall.sol";
import "./Initializable.sol";
import "./Signatures.sol";

contract MetaTransactionWallet is
  IMetaTransactionWallet,
  ICeloVersionedContract,
  Initializable,
  Ownable
{
  using SafeMath for uint256;
  using BytesLib for bytes;

  bytes32 public eip712DomainSeparator;
  // The EIP712 typehash for ExecuteMetaTransaction, i.e. keccak256(
  // "ExecuteMetaTransaction(address destination,uint256 value,bytes data,uint256 nonce)");
  bytes32 public constant EIP712_EXECUTE_META_TRANSACTION_TYPEHASH = (
    0x509c6e92324b7214543573524d0bb493d654d3410fa4f4937b3d2f4a903edd33
  );
  uint256 public nonce;
  address public signer;

  event SignerSet(address signer);
  event EIP712DomainSeparatorSet(bytes32 eip712DomainSeparator);
  event TransactionExecution(address destination, uint256 value, bytes data, bytes returnData);
  event MetaTransactionExecution(
    address destination,
    uint256 value,
    bytes data,
    uint256 nonce,
    bytes returnData
  );

  /**
   * @dev Fallback function allows to deposit ether.
   */
  function() external payable {}

  /**
   * @notice Returns the storage, major, minor, and patch version of the contract.
   * @return The storage, major, minor, and patch version of the contract.
   */
  function getVersionNumber() public pure returns (uint256, uint256, uint256, uint256) {
    return (1, 1, 0, 0);
  }

  /**
   * @notice Used in place of the constructor to allow the contract to be upgradable via proxy.
   * @param _signer The address authorized to execute transactions via this wallet.
   */
  function initialize(address _signer) external initializer {
    setSigner(_signer);
    setEip712DomainSeparator();
    // MetaTransactionWallet owns itself, which necessitates that all onlyOwner functions
    // be called via executeTransaction or executeMetaTransaction.
    // If the signer was the owner, onlyOwner functions would not be callable via
    // meta-transactions.
    _transferOwnership(address(this));
  }

  /**
   * @notice Transfers control of the wallet to a new signer.
   * @param _signer The address authorized to execute transactions via this wallet.
   */
  function setSigner(address _signer) public onlyOwner {
    signer = _signer;
    emit SignerSet(signer);
  }

  /**
   * @notice Sets the EIP-712 domain separator.
   * @dev Should be called every time the wallet is upgraded to a new version.
   */
  function setEip712DomainSeparator() public {
    uint256 id;
    assembly {
      id := chainid
    }
    // Note: `version` is the storage.major part of this contract's version (an
    // increase to either of these could mean backwards incompatibilities).
    eip712DomainSeparator = keccak256(
      abi.encode(
        keccak256(
          "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        ),
        keccak256(bytes("MetaTransactionWallet")),
        keccak256("1.1"),
        id,
        address(this)
      )
    );
    emit EIP712DomainSeparatorSet(eip712DomainSeparator);
  }

  /**
   * @notice Returns the struct hash of the MetaTransaction
   * @param destination The address to which the meta-transaction is to be sent.
   * @param value The CELO value to be sent with the meta-transaction.
   * @param data The data to be sent with the meta-transaction.
   * @param _nonce The nonce for this meta-transaction local to this wallet.
   * @return The digest of the provided meta-transaction.
   */
  function getMetaTransactionStructHash(
    address destination,
    uint256 value,
    bytes memory data,
    uint256 _nonce
  ) public view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          EIP712_EXECUTE_META_TRANSACTION_TYPEHASH,
          destination,
          value,
          keccak256(data),
          _nonce
        )
      );
  }

  /**
   * @notice Returns the digest of the provided meta-transaction, to be signed by `sender`.
   * @param destination The address to which the meta-transaction is to be sent.
   * @param value The CELO value to be sent with the meta-transaction.
   * @param data The data to be sent with the meta-transaction.
   * @param _nonce The nonce for this meta-transaction local to this wallet.
   * @return The digest of the provided meta-transaction.
   */
  function getMetaTransactionDigest(
    address destination,
    uint256 value,
    bytes memory data,
    uint256 _nonce
  ) public view returns (bytes32) {
    bytes32 structHash = getMetaTransactionStructHash(destination, value, data, _nonce);
    return Signatures.toEthSignedTypedDataHash(eip712DomainSeparator, structHash);
  }

  /**
   * @notice Returns the address that signed the provided meta-transaction.
   * @param destination The address to which the meta-transaction is to be sent.
   * @param value The CELO value to be sent with the meta-transaction.
   * @param data The data to be sent with the meta-transaction.
   * @param _nonce The nonce for this meta-transaction local to this wallet.
   * @param v The recovery id of the ECDSA signature of the meta-transaction.
   * @param r Output value r of the ECDSA signature.
   * @param s Output value s of the ECDSA signature.
   * @return The address that signed the provided meta-transaction.
   */
  function getMetaTransactionSigner(
    address destination,
    uint256 value,
    bytes memory data,
    uint256 _nonce,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public view returns (address) {
    bytes32 structHash = getMetaTransactionStructHash(destination, value, data, _nonce);
    return Signatures.getSignerOfTypedDataHash(eip712DomainSeparator, structHash, v, r, s);
  }

  /**
   * @notice Executes a meta-transaction on behalf of the signer.
   * @param destination The address to which the meta-transaction is to be sent.
   * @param value The CELO value to be sent with the meta-transaction.
   * @param data The data to be sent with the meta-transaction.
   * @param v The recovery id of the ECDSA signature of the meta-transaction.
   * @param r Output value r of the ECDSA signature.
   * @param s Output value s of the ECDSA signature.
   * @return The return value of the meta-transaction execution.
   */
  function executeMetaTransaction(
    address destination,
    uint256 value,
    bytes calldata data,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external returns (bytes memory) {
    address _signer = getMetaTransactionSigner(destination, value, data, nonce, v, r, s);
    require(_signer == signer, "Invalid meta-transaction signer");
    nonce = nonce.add(1);
    bytes memory returnData = ExternalCall.execute(destination, value, data);
    emit MetaTransactionExecution(destination, value, data, nonce.sub(1), returnData);
    return returnData;
  }

  /**
   * @notice Executes a transaction on behalf of the signer.`
   * @param destination The address to which the transaction is to be sent.
   * @param value The CELO value to be sent with the transaction.
   * @param data The data to be sent with the transaction.
   * @return The return value of the transaction execution.
   */
  function executeTransaction(address destination, uint256 value, bytes memory data)
    public
    returns (bytes memory)
  {
    // Allowing the owner to call execute transaction allows, when the contract is self-owned,
    // for the signer to sign and execute a batch of transactions via a meta-transaction.
    require(msg.sender == signer || msg.sender == owner(), "Invalid transaction sender");
    bytes memory returnData = ExternalCall.execute(destination, value, data);
    emit TransactionExecution(destination, value, data, returnData);
    return returnData;
  }

  /**
   * @notice Executes multiple transactions on behalf of the signer.`
   * @param destinations The address to which each transaction is to be sent.
   * @param values The CELO value to be sent with each transaction.
   * @param data The concatenated data to be sent in each transaction.
   * @param dataLengths The length of each transaction's data.
   */
  function executeTransactions(
    address[] calldata destinations,
    uint256[] calldata values,
    bytes calldata data,
    uint256[] calldata dataLengths
  ) external {
    require(
      destinations.length == values.length && values.length == dataLengths.length,
      "Input arrays must be same length"
    );
    uint256 dataPosition = 0;
    for (uint256 i = 0; i < destinations.length; i++) {
      executeTransaction(destinations[i], values[i], sliceData(data, dataPosition, dataLengths[i]));
      dataPosition = dataPosition.add(dataLengths[i]);
    }
  }

  /**
   * @notice Returns a slice from a byte array.
   * @param data The byte array.
   * @param start The start index of the slice to take.
   * @param length The length of the slice to take.
   * @return A slice from a byte array.
   */
  function sliceData(bytes memory data, uint256 start, uint256 length)
    internal
    returns (bytes memory)
  {
    // When length == 0 bytes.slice does not seem to always return an empty byte array.
    bytes memory sliced;
    if (length > 0) {
      sliced = data.slice(start, length);
    }
    return sliced;
  }
}
