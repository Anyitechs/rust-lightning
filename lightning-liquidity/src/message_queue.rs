// This file is Copyright its original authors, visible in version control
// history.
//
// This file is licensed under the Apache License, Version 2.0 <LICENSE-APACHE
// or http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your option.
// You may not use this file except in accordance with one or both of these
// licenses.

//! Holds types and traits used to implement message queues for [`LSPSMessage`]s.

use alloc::collections::VecDeque;
use alloc::vec::Vec;

use crate::lsps0::ser::LSPSMessage;
use crate::sync::{Arc, Mutex};

use lightning::util::wakers::Notifier;

use bitcoin::secp256k1::PublicKey;

/// The default [`MessageQueue`] Implementation used by [`LiquidityManager`].
///
/// [`LiquidityManager`]: crate::LiquidityManager
pub struct MessageQueue {
	queue: Mutex<VecDeque<(PublicKey, LSPSMessage)>>,
	pending_msgs_notifier: Arc<Notifier>,
}

impl MessageQueue {
	pub(crate) fn new(pending_msgs_notifier: Arc<Notifier>) -> Self {
		let queue = Mutex::new(VecDeque::new());
		Self { queue, pending_msgs_notifier }
	}

	pub(crate) fn get_and_clear_pending_msgs(&self) -> Vec<(PublicKey, LSPSMessage)> {
		self.queue.lock().unwrap().drain(..).collect()
	}

	pub(crate) fn notifier(&self) -> MessageQueueNotifierGuard<'_> {
		MessageQueueNotifierGuard { msg_queue: self, buffer: VecDeque::new() }
	}
}

// A guard type that will process buffered messages and wake the background processor when dropped.
#[must_use]
pub(crate) struct MessageQueueNotifierGuard<'a> {
	msg_queue: &'a MessageQueue,
	buffer: VecDeque<(PublicKey, LSPSMessage)>,
}

impl<'a> MessageQueueNotifierGuard<'a> {
	pub fn enqueue(&mut self, counterparty_node_id: &PublicKey, msg: LSPSMessage) {
		self.buffer.push_back((*counterparty_node_id, msg));
	}
}

impl<'a> Drop for MessageQueueNotifierGuard<'a> {
	fn drop(&mut self) {
		if !self.buffer.is_empty() {
			self.msg_queue.queue.lock().unwrap().append(&mut self.buffer);
			self.msg_queue.pending_msgs_notifier.notify();
		}
	}
}
