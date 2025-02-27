use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use starknet::core::{types::FieldElement, types::*};

use crate::storage::{BridgeChain, CrossChainTx, CrossChainTxKind, Event, EventLabel, Request};

pub const DEPOSIT_REQUEST_INITIATED_SELECTOR: &str =
    "0x1682ccdc90fbee2d6cc3e930539cb4ca29390a438db1c2e4c7d493e01a61abb";

pub const WITHDRAW_REQUEST_COMPLETED_SELECTOR: &str =
    "0x132aab9714c265c8ad151ce006bb91691100722ddec42e7ee96dc9dfa9e741c";

pub const REQUEST_HEADER_WITHDRAW_AUTO: u128 = 0x01000000;
pub const REQUEST_HEADER_BURN_AUTO: u128 = 0x010000;

///
pub fn get_store_data(
    event: EmittedEvent,
) -> Result<(Option<Request>, Option<Event>, Vec<CrossChainTx>)> {
    // keys[0] -> selector.
    // keys[1,2] -> req hash.
    // keys[3] -> timestamp.
    let hash = u256_to_hex(&event.keys[1..])?;
    let block_timestamp = event.keys[3];
    let request_header = event.data[0];

    let mut store_event = Event {
        req_hash: hash.clone(),
        label: EventLabel::DepositInitiatedL2,
        block_timestamp: block_timestamp.try_into()?,
        block_number: event.block_number,
        tx_hash: felt_to_hex(&event.transaction_hash),
    };

    let mut txs = vec![];

    match felt_to_hex(&event.keys[0]).as_str() {
        DEPOSIT_REQUEST_INITIATED_SELECTOR => {
            store_event.label = EventLabel::DepositInitiatedL2;

            let request = request_from_event_data(&store_event.label, event.data)?;

            // txs are only valid for deposit.
            txs = get_xchain_txs(
                request_header,
                request.hash.clone(),
                request.content.clone(),
            )?;

            assert_eq!(request.hash, store_event.req_hash);
            Ok((Some(request), Some(store_event), txs))
        }
        WITHDRAW_REQUEST_COMPLETED_SELECTOR => {
            store_event.label = EventLabel::WithdrawCompletedL2;

            let request = request_from_event_data(&store_event.label, event.data)?;

            assert_eq!(request.hash, store_event.req_hash);
            Ok((Some(request), Some(store_event), txs))
        }
        _ => Ok((None, None, vec![])),
    }
}

/// From the raw buffer in the event data, parse the request fields
/// required to build `Request`.
fn request_from_event_data(event_label: &EventLabel, data: Vec<FieldElement>) -> Result<Request> {
    // First 7 felts are the fixed size part of the request.
    if data.len() < 7 {
        return Err(anyhow!(
            "Request can't be extracted from event data: {:?}",
            data
        ));
    }

    let content_array: Vec<Value> = data.iter().map(|f| json!(felt_to_hex(f))).collect();
    let content = serde_json::to_string(&content_array)?;

    let req = match event_label {
        EventLabel::DepositInitiatedL2 => Request {
            hash: u256_to_hex(&data[1..])?, // first felt is the header.
            chain_src: BridgeChain::Starknet,
            collection_src: felt_to_hex(&data[4]), // collection l2
            collection_dst: felt_to_hex(&data[3]), // collection l1
            from: felt_to_hex(&data[6]),           // owner l2
            to: felt_to_hex(&data[5]),             // owner l1
            content,
        },
        EventLabel::WithdrawCompletedL2 => Request {
            hash: u256_to_hex(&data[1..])?, // first felt is the header.
            chain_src: BridgeChain::Ethereum,
            collection_src: felt_to_hex(&data[3]), // collection l1
            collection_dst: felt_to_hex(&data[4]), // collection l2
            from: felt_to_hex(&data[5]),           // owner l1
            to: felt_to_hex(&data[6]),             // owner l2
            content,
        },
        _ => {
            return Err(anyhow!(
                "EventLabel {:?} not supposed to generate a request",
                event_label
            ))
        }
    };

    Ok(req)
}

///
fn get_xchain_txs(
    header: FieldElement,
    req_hash: String,
    req_content: String,
) -> Result<Vec<CrossChainTx>> {
    // For now, header must be convertible into u128.
    let h: u128 = header.try_into()?;

    let can_withdraw_auto = h & REQUEST_HEADER_WITHDRAW_AUTO == REQUEST_HEADER_WITHDRAW_AUTO;
    let can_burn_auto = h & REQUEST_HEADER_BURN_AUTO == REQUEST_HEADER_BURN_AUTO;

    // Txs that will target Ethereum bridge contract.
    let mut txs: Vec<CrossChainTx> = vec![];

    if can_withdraw_auto {
        txs.push(CrossChainTx {
            chain: BridgeChain::Ethereum,
            kind: CrossChainTxKind::WithdrawAuto,
            req_hash: req_hash.clone(),
            req_content: req_content.clone(),
            tx_hash: String::from(""),
        });
    }

    if can_burn_auto {
        txs.push(CrossChainTx {
            chain: BridgeChain::Ethereum,
            kind: CrossChainTxKind::BurnAuto,
            req_hash: req_hash.clone(),
            req_content: req_content.clone(),
            tx_hash: String::from(""),
        });
    }

    Ok(txs)
}

/// Always with leading 0 for u256.
fn u256_to_hex(felts: &[FieldElement]) -> Result<String> {
    if felts.len() < 2 {
        return Err(anyhow!("At least two felts are required to read a u256"));
    }

    Ok(format!("{:#32x}{:32x}", felts[1], felts[0]))
}

///
#[inline(always)]
fn felt_to_hex(fe: &FieldElement) -> String {
    format!("{:#64x}", fe)
}
