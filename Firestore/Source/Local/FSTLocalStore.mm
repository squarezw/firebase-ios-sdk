/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Source/Local/FSTLocalStore.h"

#include <memory>
#include <set>
#include <unordered_map>
#include <utility>
#include <vector>

#import "FIRTimestamp.h"

#include "Firestore/core/include/firebase/firestore/timestamp.h"
#include "Firestore/core/src/firebase/firestore/auth/user.h"
#include "Firestore/core/src/firebase/firestore/core/target_id_generator.h"
#include "Firestore/core/src/firebase/firestore/immutable/sorted_set.h"
#include "Firestore/core/src/firebase/firestore/local/local_documents_view.h"
#include "Firestore/core/src/firebase/firestore/local/local_view_changes.h"
#include "Firestore/core/src/firebase/firestore/local/local_write_result.h"
#include "Firestore/core/src/firebase/firestore/local/mutation_queue.h"
#include "Firestore/core/src/firebase/firestore/local/persistence.h"
#include "Firestore/core/src/firebase/firestore/local/query_cache.h"
#include "Firestore/core/src/firebase/firestore/local/query_data.h"
#include "Firestore/core/src/firebase/firestore/local/reference_set.h"
#include "Firestore/core/src/firebase/firestore/local/remote_document_cache.h"
#include "Firestore/core/src/firebase/firestore/model/document_key_set.h"
#include "Firestore/core/src/firebase/firestore/model/document_map.h"
#include "Firestore/core/src/firebase/firestore/model/mutation_batch.h"
#include "Firestore/core/src/firebase/firestore/model/mutation_batch_result.h"
#include "Firestore/core/src/firebase/firestore/model/patch_mutation.h"
#include "Firestore/core/src/firebase/firestore/model/snapshot_version.h"
#include "Firestore/core/src/firebase/firestore/nanopb/nanopb_util.h"
#include "Firestore/core/src/firebase/firestore/remote/remote_event.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/log.h"
#include "Firestore/core/src/firebase/firestore/util/to_string.h"
#include "absl/memory/memory.h"
#include "absl/types/optional.h"

namespace util = firebase::firestore::util;
using firebase::Timestamp;
using firebase::firestore::auth::User;
using firebase::firestore::core::Query;
using firebase::firestore::core::TargetIdGenerator;
using firebase::firestore::local::LocalDocumentsView;
using firebase::firestore::local::LocalViewChanges;
using firebase::firestore::local::LocalWriteResult;
using firebase::firestore::local::LruResults;
using firebase::firestore::local::MutationQueue;
using firebase::firestore::local::Persistence;
using firebase::firestore::local::QueryCache;
using firebase::firestore::local::QueryData;
using firebase::firestore::local::QueryPurpose;
using firebase::firestore::local::ReferenceSet;
using firebase::firestore::local::RemoteDocumentCache;
using firebase::firestore::model::BatchId;
using firebase::firestore::model::DocumentKey;
using firebase::firestore::model::DocumentKeySet;
using firebase::firestore::model::DocumentMap;
using firebase::firestore::model::DocumentVersionMap;
using firebase::firestore::model::FieldMask;
using firebase::firestore::model::FieldPath;
using firebase::firestore::model::ListenSequenceNumber;
using firebase::firestore::model::MaybeDocument;
using firebase::firestore::model::MaybeDocumentMap;
using firebase::firestore::model::Mutation;
using firebase::firestore::model::MutationBatch;
using firebase::firestore::model::MutationBatchResult;
using firebase::firestore::model::ObjectValue;
using firebase::firestore::model::OptionalMaybeDocumentMap;
using firebase::firestore::model::PatchMutation;
using firebase::firestore::model::Precondition;
using firebase::firestore::model::SnapshotVersion;
using firebase::firestore::model::TargetId;
using firebase::firestore::nanopb::ByteString;
using firebase::firestore::remote::RemoteEvent;
using firebase::firestore::remote::TargetChange;

NS_ASSUME_NONNULL_BEGIN

/**
 * The maximum time to leave a resume token buffered without writing it out. This value is
 * arbitrary: it's long enough to avoid several writes (possibly indefinitely if updates come more
 * frequently than this) but short enough that restarting after crashing will still have a pretty
 * recent resume token.
 */
static const int64_t kResumeTokenMaxAgeSeconds = 5 * 60;  // 5 minutes

@interface FSTLocalStore ()

/** Maps a query to the data about that query. */
@property(nonatomic) QueryCache *queryCache;

@end

@implementation FSTLocalStore {
  /** Manages our in-memory or durable persistence. Owned by FirestoreClient. */
  Persistence *_persistence;

  /** Used to generate targetIDs for queries tracked locally. */
  TargetIdGenerator _targetIDGenerator;
  /** The set of all cached remote documents. */
  RemoteDocumentCache *_remoteDocumentCache;
  QueryCache *_queryCache;
  /** The set of all mutations that have been sent but not yet been applied to the backend. */
  MutationQueue *_mutationQueue;

  /** The "local" view of all documents (layering mutationQueue on top of remoteDocumentCache). */
  std::unique_ptr<LocalDocumentsView> _localDocuments;

  /** The set of document references maintained by any local views. */
  ReferenceSet _localViewReferences;

  /** Maps a targetID to data about its query. */
  std::unordered_map<TargetId, QueryData> _targetIDs;
}

- (instancetype)initWithPersistence:(Persistence *)persistence
                        initialUser:(const User &)initialUser {
  if (self = [super init]) {
    _persistence = persistence;
    _mutationQueue = persistence->GetMutationQueueForUser(initialUser);
    _remoteDocumentCache = persistence->remote_document_cache();
    _queryCache = persistence->query_cache();
    _localDocuments = absl::make_unique<LocalDocumentsView>(_remoteDocumentCache, _mutationQueue,
                                                            persistence->index_manager());
    persistence->reference_delegate()->AddInMemoryPins(&_localViewReferences);

    _targetIDGenerator = TargetIdGenerator::QueryCacheTargetIdGenerator(0);
  }
  return self;
}

- (void)start {
  [self startMutationQueue];
  TargetId targetID = _queryCache->highest_target_id();
  _targetIDGenerator = TargetIdGenerator::QueryCacheTargetIdGenerator(targetID);
}

- (void)startMutationQueue {
  _persistence->Run("Start MutationQueue", [&] { _mutationQueue->Start(); });
}

- (MaybeDocumentMap)userDidChange:(const User &)user {
  // Swap out the mutation queue, grabbing the pending mutation batches before and after.
  std::vector<MutationBatch> oldBatches =
      _persistence->Run("OldBatches", [&] { return _mutationQueue->AllMutationBatches(); });

  // The old one has a reference to the mutation queue, so nil it out first.
  _localDocuments.reset();
  _mutationQueue = _persistence->GetMutationQueueForUser(user);

  [self startMutationQueue];

  return _persistence->Run("NewBatches", [&] {
    std::vector<MutationBatch> newBatches = _mutationQueue->AllMutationBatches();

    // Recreate our LocalDocumentsView using the new MutationQueue.
    _localDocuments = absl::make_unique<LocalDocumentsView>(_remoteDocumentCache, _mutationQueue,
                                                            _persistence->index_manager());

    // Union the old/new changed keys.
    DocumentKeySet changedKeys;
    for (const std::vector<MutationBatch> *batches : {&oldBatches, &newBatches}) {
      for (const MutationBatch &batch : *batches) {
        for (const Mutation &mutation : batch.mutations()) {
          changedKeys = changedKeys.insert(mutation.key());
        }
      }
    }

    // Return the set of all (potentially) changed documents as the result of the user change.
    return _localDocuments->GetDocuments(changedKeys);
  });
}

- (LocalWriteResult)locallyWriteMutations:(std::vector<Mutation> &&)mutations {
  Timestamp localWriteTime = Timestamp::Now();
  DocumentKeySet keys;
  for (const Mutation &mutation : mutations) {
    keys = keys.insert(mutation.key());
  }

  return _persistence->Run("Locally write mutations", [&] {
    // Load and apply all existing mutations. This lets us compute the current base state for
    // all non-idempotent transforms before applying any additional user-provided writes.
    MaybeDocumentMap existingDocuments = _localDocuments->GetDocuments(keys);

    // For non-idempotent mutations (such as `FieldValue.increment()`), we record the base
    // state in a separate patch mutation. This is later used to guarantee consistent values
    // and prevents flicker even if the backend sends us an update that already includes our
    // transform.
    std::vector<Mutation> baseMutations;
    for (const Mutation &mutation : mutations) {
      absl::optional<MaybeDocument> base_document = existingDocuments.get(mutation.key());

      absl::optional<ObjectValue> base_value = mutation.ExtractBaseValue(base_document);
      if (base_value) {
        // NOTE: The base state should only be applied if there's some existing document to
        // override, so use a Precondition of exists=true
        baseMutations.push_back(PatchMutation(
            mutation.key(), *base_value, base_value->ToFieldMask(), Precondition::Exists(true)));
      }
    }

    MutationBatch batch = _mutationQueue->AddMutationBatch(localWriteTime, std::move(baseMutations),
                                                           std::move(mutations));
    MaybeDocumentMap changedDocuments = batch.ApplyToLocalDocumentSet(existingDocuments);
    return LocalWriteResult{batch.batch_id(), std::move(changedDocuments)};
  });
}

- (MaybeDocumentMap)acknowledgeBatchWithResult:(const MutationBatchResult &)batchResult {
  return _persistence->Run("Acknowledge batch", [&] {
    const MutationBatch &batch = batchResult.batch();
    _mutationQueue->AcknowledgeBatch(batch, batchResult.stream_token());
    [self applyBatchResult:batchResult];
    _mutationQueue->PerformConsistencyCheck();

    return _localDocuments->GetDocuments(batch.keys());
  });
}

- (MaybeDocumentMap)rejectBatchID:(BatchId)batchID {
  return _persistence->Run("Reject batch", [&] {
    absl::optional<MutationBatch> toReject = _mutationQueue->LookupMutationBatch(batchID);
    HARD_ASSERT(toReject.has_value(), "Attempt to reject nonexistent batch!");

    _mutationQueue->RemoveMutationBatch(*toReject);
    _mutationQueue->PerformConsistencyCheck();

    return _localDocuments->GetDocuments(toReject->keys());
  });
}

- (ByteString)lastStreamToken {
  return _mutationQueue->GetLastStreamToken();
}

- (void)setLastStreamToken:(const ByteString &)streamToken {
  _persistence->Run("Set stream token", [&] { _mutationQueue->SetLastStreamToken(streamToken); });
}

- (const SnapshotVersion &)lastRemoteSnapshotVersion {
  return self.queryCache->GetLastRemoteSnapshotVersion();
}

- (MaybeDocumentMap)applyRemoteEvent:(const RemoteEvent &)remoteEvent {
  const SnapshotVersion &lastRemoteVersion = _queryCache->GetLastRemoteSnapshotVersion();

  return _persistence->Run("Apply remote event", [&] {
    // TODO(gsoltis): move the sequence number into the reference delegate.
    ListenSequenceNumber sequenceNumber = _persistence->current_sequence_number();

    for (const auto &entry : remoteEvent.target_changes()) {
      TargetId targetID = entry.first;
      const TargetChange &change = entry.second;

      auto found = _targetIDs.find(targetID);
      if (found == _targetIDs.end()) {
        // We don't update the remote keys if the query is not active. This ensures that
        // we persist the updated query data along with the updated assignment.
        continue;
      }

      QueryData oldQueryData = found->second;

      _queryCache->RemoveMatchingKeys(change.removed_documents(), targetID);
      _queryCache->AddMatchingKeys(change.added_documents(), targetID);

      // Update the resume token if the change includes one. Don't clear any preexisting value.
      // Bump the sequence number as well, so that documents being removed now are ordered later
      // than documents that were previously removed from this target.
      const ByteString &resumeToken = change.resume_token();
      // Update the resume token if the change includes one.
      if (!resumeToken.empty()) {
        QueryData newQueryData =
            oldQueryData.Copy(remoteEvent.snapshot_version(), resumeToken, sequenceNumber);
        _targetIDs[targetID] = newQueryData;

        // Update the query data if there are target changes (or if sufficient time has
        // passed since the last update).
        if ([self shouldPersistQueryData:newQueryData oldQueryData:oldQueryData change:change]) {
          _queryCache->UpdateTarget(newQueryData);
        }
      }
    }

    OptionalMaybeDocumentMap changedDocs;
    const DocumentKeySet &limboDocuments = remoteEvent.limbo_document_changes();
    DocumentKeySet updatedKeys;
    for (const auto &kv : remoteEvent.document_updates()) {
      updatedKeys = updatedKeys.insert(kv.first);
    }
    // Each loop iteration only affects its "own" doc, so it's safe to get all the remote
    // documents in advance in a single call.
    OptionalMaybeDocumentMap existingDocs = _remoteDocumentCache->GetAll(updatedKeys);

    for (const auto &kv : remoteEvent.document_updates()) {
      const DocumentKey &key = kv.first;
      const MaybeDocument &doc = kv.second;
      absl::optional<MaybeDocument> existingDoc;
      auto foundExisting = existingDocs.get(key);
      if (foundExisting) {
        existingDoc = *foundExisting;
      }

      // Note: The order of the steps below is important, since we want to ensure that
      // rejected limbo resolutions (which fabricate NoDocuments with SnapshotVersion::None)
      // never add documents to cache.
      if (doc.type() == MaybeDocument::Type::NoDocument &&
          doc.version() == SnapshotVersion::None()) {
        // NoDocuments with SnapshotVersion::None are used in manufactured events. We remove
        // these documents from cache since we lost access.
        _remoteDocumentCache->Remove(key);
        changedDocs = changedDocs.insert(key, doc);
      } else if (!existingDoc || doc.version() > existingDoc->version() ||
                 (doc.version() == existingDoc->version() && existingDoc->has_pending_writes())) {
        // TODO(index-free): Comment in this assert when we enable Index-Free queries
        // HARD_ASSERT(remoteEvent.snapshot_version() != SnapshotVersion::None(),
        //            "Cannot add a document when the remote version is zero");
        _remoteDocumentCache->Add(doc);
        changedDocs = changedDocs.insert(key, doc);
      } else {
        LOG_DEBUG("FSTLocalStore Ignoring outdated watch update for %s. "
                  "Current version: %s  Watch version: %s",
                  key.ToString(), existingDoc->version().ToString(), doc.version().ToString());
      }

      // If this was a limbo resolution, make sure we mark when it was accessed.
      if (limboDocuments.contains(key)) {
        _persistence->reference_delegate()->UpdateLimboDocument(key);
      }
    }

    // HACK: The only reason we allow omitting snapshot version is so we can synthesize remote
    // events when we get permission denied errors while trying to resolve the state of a locally
    // cached document that is in limbo.
    const SnapshotVersion &remoteVersion = remoteEvent.snapshot_version();
    if (remoteVersion != SnapshotVersion::None()) {
      HARD_ASSERT(remoteVersion >= lastRemoteVersion,
                  "Watch stream reverted to previous snapshot?? (%s < %s)",
                  remoteVersion.ToString(), lastRemoteVersion.ToString());
      _queryCache->SetLastRemoteSnapshotVersion(remoteVersion);
    }

    return _localDocuments->GetLocalViewOfDocuments(changedDocs);
  });
}

/**
 * Returns YES if the newQueryData should be persisted during an update of an active target.
 * QueryData should always be persisted when a target is being released and should not call this
 * function.
 *
 * While the target is active, QueryData updates can be omitted when nothing about the target has
 * changed except metadata like the resume token or snapshot version. Occasionally it's worth the
 * extra write to prevent these values from getting too stale after a crash, but this doesn't have
 * to be too frequent.
 */
- (BOOL)shouldPersistQueryData:(const QueryData &)newQueryData
                  oldQueryData:(const QueryData &)oldQueryData
                        change:(const TargetChange &)change {
  // Avoid clearing any existing value
  HARD_ASSERT(!newQueryData.resume_token().empty(),
              "Attempted to persist query data with empty resume token");

  // Always persist query data if we don't already have a resume token.
  if (oldQueryData.resume_token().empty()) return YES;

  // Don't allow resume token changes to be buffered indefinitely. This allows us to be reasonably
  // up-to-date after a crash and avoids needing to loop over all active queries on shutdown.
  // Especially in the browser we may not get time to do anything interesting while the current
  // tab is closing.
  int64_t newSeconds = newQueryData.snapshot_version().timestamp().seconds();
  int64_t oldSeconds = oldQueryData.snapshot_version().timestamp().seconds();
  int64_t timeDelta = newSeconds - oldSeconds;
  if (timeDelta >= kResumeTokenMaxAgeSeconds) return YES;

  // Otherwise if the only thing that has changed about a target is its resume token then it's not
  // worth persisting. Note that the RemoteStore keeps an in-memory view of the currently active
  // targets which includes the current resume token, so stream failure or user changes will still
  // use an up-to-date resume token regardless of what we do here.
  size_t changes = change.added_documents().size() + change.modified_documents().size() +
                   change.removed_documents().size();
  return changes > 0;
}

- (void)notifyLocalViewChanges:(const std::vector<LocalViewChanges> &)viewChanges {
  _persistence->Run("NotifyLocalViewChanges", [&] {
    for (const LocalViewChanges &viewChange : viewChanges) {
      for (const DocumentKey &key : viewChange.removed_keys()) {
        _persistence->reference_delegate()->RemoveReference(key);
      }
      _localViewReferences.AddReferences(viewChange.added_keys(), viewChange.target_id());
      _localViewReferences.RemoveReferences(viewChange.removed_keys(), viewChange.target_id());
    }
  });
}

- (absl::optional<MutationBatch>)nextMutationBatchAfterBatchID:(BatchId)batchID {
  return _persistence->Run("NextMutationBatchAfterBatchID",
                           [&] { return _mutationQueue->NextMutationBatchAfterBatchId(batchID); });
}

- (absl::optional<MaybeDocument>)readDocument:(const DocumentKey &)key {
  return _persistence->Run("ReadDocument", [&] { return _localDocuments->GetDocument(key); });
}

- (model::BatchId)getHighestUnacknowledgedBatchId {
  return _persistence->Run("getHighestUnacknowledgedBatchId",
                           [&] { return _mutationQueue->GetHighestUnacknowledgedBatchId(); });
}

- (QueryData)allocateQuery:(Query)query {
  QueryData queryData = _persistence->Run("Allocate query", [&] {
    absl::optional<QueryData> cached = _queryCache->GetTarget(query);
    // TODO(mcg): freshen last accessed date if cached exists?
    if (!cached) {
      cached = QueryData(query, _targetIDGenerator.NextId(),
                         _persistence->current_sequence_number(), QueryPurpose::Listen);
      _queryCache->AddTarget(*cached);
    }
    return *cached;
  });
  // Sanity check to ensure that even when resuming a query it's not currently active.
  TargetId targetID = queryData.target_id();
  HARD_ASSERT(_targetIDs.find(targetID) == _targetIDs.end(),
              "Tried to allocate an already allocated query: %s", query.ToString());
  _targetIDs[targetID] = queryData;
  return queryData;
}

- (void)releaseQuery:(const Query &)query {
  _persistence->Run("Release query", [&] {
    absl::optional<QueryData> queryData = _queryCache->GetTarget(query);
    HARD_ASSERT(queryData, "Tried to release nonexistent query: %s", query.ToString());

    TargetId targetID = queryData->target_id();

    auto found = _targetIDs.find(targetID);
    if (found != _targetIDs.end()) {
      const QueryData &cachedQueryData = found->second;

      if (cachedQueryData.snapshot_version() > queryData->snapshot_version()) {
        // If we've been avoiding persisting the resumeToken (see shouldPersistQueryData for
        // conditions and rationale) we need to persist the token now because there will no
        // longer be an in-memory version to fall back on.
        queryData = cachedQueryData;
        _queryCache->UpdateTarget(*queryData);
      }
    }

    // References for documents sent via Watch are automatically removed when we delete a
    // query's target data from the reference delegate. Since this does not remove references
    // for locally mutated documents, we have to remove the target associations for these
    // documents manually.
    DocumentKeySet removed = _localViewReferences.RemoveReferences(targetID);
    for (const DocumentKey &key : removed) {
      _persistence->reference_delegate()->RemoveReference(key);
    }
    _targetIDs.erase(targetID);
    _persistence->reference_delegate()->RemoveTarget(*queryData);
  });
}

- (DocumentMap)executeQuery:(const Query &)query {
  return _persistence->Run("ExecuteQuery",
                           [&] { return _localDocuments->GetDocumentsMatchingQuery(query); });
}

- (DocumentKeySet)remoteDocumentKeysForTarget:(TargetId)targetID {
  return _persistence->Run("RemoteDocumentKeysForTarget",
                           [&] { return _queryCache->GetMatchingKeys(targetID); });
}

- (void)applyBatchResult:(const MutationBatchResult &)batchResult {
  const MutationBatch &batch = batchResult.batch();
  DocumentKeySet docKeys = batch.keys();
  const DocumentVersionMap &versions = batchResult.doc_versions();
  for (const DocumentKey &docKey : docKeys) {
    absl::optional<MaybeDocument> remoteDoc = _remoteDocumentCache->Get(docKey);
    absl::optional<MaybeDocument> doc = remoteDoc;

    auto ackVersionIter = versions.find(docKey);
    HARD_ASSERT(ackVersionIter != versions.end(),
                "docVersions should contain every doc in the write.");
    const SnapshotVersion &ackVersion = ackVersionIter->second;
    if (!doc || doc->version() < ackVersion) {
      doc = batch.ApplyToRemoteDocument(doc, docKey, batchResult);
      if (!doc) {
        HARD_ASSERT(!remoteDoc, "Mutation batch %s applied to document %s resulted in nullopt.",
                    batch.ToString(), util::ToString(remoteDoc));
      } else {
        _remoteDocumentCache->Add(*doc);
      }
    }
  }

  _mutationQueue->RemoveMutationBatch(batch);
}

- (LruResults)collectGarbage:(local::LruGarbageCollector *)garbageCollector {
  return _persistence->Run("Collect garbage",
                           [&] { return garbageCollector->Collect(_targetIDs); });
}

@end

NS_ASSUME_NONNULL_END
