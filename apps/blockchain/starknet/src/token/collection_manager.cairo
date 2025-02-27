use serde::Serde;
use traits::Into;
use array::{ArrayTrait, SpanTrait};
use result::ResultTrait;
use option::OptionTrait;
use zeroable::Zeroable;
use starknet::{ContractAddress, ClassHash, EthAddress};
use starknet::contract_address::ContractAddressZeroable;
use starknet::eth_address::EthAddressZeroable;
use starklane::string::{LongString, SpanFeltSerializedTryIntoLongString};
use super::interfaces::{IERC721Dispatcher, IERC721DispatcherTrait};

#[derive(Drop, PartialEq)]
enum CollectionType {
    ERC721: (),
    ERC1155: (),
}

#[derive(Drop)]
struct ERC721Metadata {
    name: LongString,
    symbol: LongString,
    base_uri: LongString,
    uris: Span<LongString>,
}

/// Extracts metadata of the given ERC721 contract.
///
/// # Arguments
///
/// * `erc721` - Dispatcher of ERC721 contract.
/// * `token_ids` - An optional list of token to extract individual URI.
fn erc721_metadata(
    contract_address: ContractAddress,
    token_ids: Option<Span<u256>>
) -> Option<ERC721Metadata> {
    let erc721 = IERC721Dispatcher { contract_address };

    let uris = match token_ids {
        Option::Some(ids) => {
            let mut out_uris = array![];
            let mut i = 0_usize;
            loop {
                if i == ids.len() {
                    break ();
                }

                let token_id = *ids[i];
                let token_uri =
                    match token_uri_from_contract_call(erc721.contract_address, token_id) {
                        Option::Some(uri) => uri,
                        Option::None => ''.into(),
                    };

                out_uris.append(token_uri);

                i += 1;
            };

            out_uris.span()
        },
        Option::None => {
            array![].span()
        }
    };

    Option::Some(
        ERC721Metadata {
            name: erc721.name(),
            symbol: erc721.symbol(),
            base_uri: ''.into(),
            uris
        }
    )
}

/// Returns a new URI after a call to
/// the contract expected to support ERC721 metadata.
///
/// This function will try both selectors: token_uri and tokenUri.
///
/// Also, this implementation supports several ways of implementing
/// a token URI:
/// 1. A simple felt
/// 2. An array of felts serialized (starting with the length)
///
/// * `collection_address` - Collection address of the collection.
/// * `token_id` - Token id.
fn token_uri_from_contract_call(
    collection_address: ContractAddress,
    token_id: u256,
) -> Option<LongString> {
    // TODO: add the interface detection when the standard is out.

    let token_uri_selector = 0x0226ad7e84c1fe08eb4c525ed93cccadf9517670341304571e66f7c4f95cbe54;
    let tokenUri_selector = 0x0362dec5b8b67ab667ad08e83a2c3ba1db7fdb4ab8dc3a33c057c4fddec8d3de;

    let mut _calldata: Array<felt252> = array![];
    token_id.serialize(ref _calldata);

    let calldata = _calldata.span();

    // As we use syscall, the return value is a raw span of serialized data.
    match starknet::call_contract_syscall(
        collection_address,
        token_uri_selector,
        calldata,
    ) {
        Result::Ok(span) => SpanFeltSerializedTryIntoLongString::try_into(span),
        Result::Err(e) => {
            match starknet::call_contract_syscall(
                collection_address, tokenUri_selector, calldata,
            ) {
                Result::Ok(span) => SpanFeltSerializedTryIntoLongString::try_into(span),
                Result::Err(e) => {
                    Option::None
                }
            }
        }
    }
}

/// Returns the address of a newly deployed an erc721 bridegable contract.
///
/// # Arguments
///
/// * `class_hash` - Class hash of the contract.
/// * `salt` - Salt to use on deploy to compute the address.
/// * `name` - Descriptive name of the collection.
/// * `symbol` - Abbreviated name of the collection.
/// * `bridge_address` - Address of the bridge contract.
fn deploy_erc721_bridgeable(
    class_hash: ClassHash,
    salt: felt252,
    name: LongString,
    symbol: LongString,
    bridge_address: ContractAddress,
) -> ContractAddress {
    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    calldata.append(bridge_address.into());
    // For now, the bridge is by default the collection owner.
    calldata.append(bridge_address.into());

    // Last argument false -> set the address of the contract using this function
    // as the contract's deployed address.
    match starknet::deploy_syscall(class_hash, salt, calldata.span(), false) {
        Result::Ok((addr, _)) => addr,
        // TODO: do we want an event emitted here?
        Result::Err(revert_reason) => panic(revert_reason)
    }
}

/// Returns the contract address of the collection on starknet.
/// If the collection is already mapped, the address is returned,
/// 0x0 otherwise meaning that a collection must be deployed.
///
/// # Arguments
///
/// * `l1_req` - Contract address on L1 value into the request.
/// * `l2_req` - Contract address on L2 value into the request.
/// * `l1_bridge` - Contract address on L1 in the bridge storage.
/// * `l2_bridge` - Contract address on L2 in the bridge storage.
fn verify_collection_address(
    l1_req: EthAddress,
    l2_req: ContractAddress,
    l1_bridge: EthAddress,
    l2_bridge: ContractAddress,
) -> ContractAddress {

    // L1 address must always be set as we receive the request from L1.
    if l1_req.is_zero() {
        panic_with_felt252('L1 address cannot be 0');
    }

    // L1 address is present in the request and L2 address is not.
    if l2_req.is_zero() {
        if l2_bridge.is_zero() {
            // It's the first token of the collection to be bridged.
            return ContractAddressZeroable::zero();
        }
    } else {
        // L1 address is present, and L2 address too.
        if l2_bridge != l2_req {
            panic_with_felt252('Invalid collection L2 address');
        }

        if l1_bridge != l1_req {
            panic_with_felt252('Invalid collection L1 address');
        }
    }

    l2_bridge
}
