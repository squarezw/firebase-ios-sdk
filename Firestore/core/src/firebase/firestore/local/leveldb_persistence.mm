/*
 * Copyright 2019 Google
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

#include "Firestore/core/src/firebase/firestore/local/leveldb_persistence.h"

#include <limits>
#include <utility>

#include "Firestore/core/src/firebase/firestore/auth/user.h"
#include "Firestore/core/src/firebase/firestore/core/database_info.h"
#include "Firestore/core/src/firebase/firestore/local/leveldb_lru_reference_delegate.h"
#include "Firestore/core/src/firebase/firestore/local/leveldb_migrations.h"
#include "Firestore/core/src/firebase/firestore/local/leveldb_util.h"
#include "Firestore/core/src/firebase/firestore/local/listen_sequence.h"
#include "Firestore/core/src/firebase/firestore/local/lru_garbage_collector.h"
#include "Firestore/core/src/firebase/firestore/local/reference_delegate.h"
#include "Firestore/core/src/firebase/firestore/local/sizer.h"
#include "Firestore/core/src/firebase/firestore/util/filesystem.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/log.h"
#include "Firestore/core/src/firebase/firestore/util/string_util.h"
#include "absl/memory/memory.h"
#include "absl/strings/match.h"

namespace firebase {
namespace firestore {
namespace local {
namespace {

using auth::User;
using leveldb::DB;
using model::ListenSequenceNumber;
using util::Path;
using util::Status;
using util::StatusOr;
using util::StringFormat;

/**
 * Finds all user ids in the database based on the existence of a mutation
 * queue.
 */
std::set<std::string> CollectUserSet(LevelDbTransaction* transaction) {
  std::set<std::string> result;

  std::string table_prefix = LevelDbMutationKey::KeyPrefix();
  auto it = transaction->NewIterator();
  it->Seek(table_prefix);

  LevelDbMutationKey row_key;
  while (it->Valid() && absl::StartsWith(it->key(), table_prefix) &&
         row_key.Decode(it->key())) {
    result.insert(row_key.user_id());

    auto user_end = LevelDbMutationKey::KeyPrefix(row_key.user_id());
    user_end = util::PrefixSuccessor(user_end);
    it->Seek(user_end);
  }
  return result;
}

}  // namespace

util::StatusOr<std::unique_ptr<LevelDbPersistence>> LevelDbPersistence::Create(
    util::Path dir,
    FSTLocalSerializer* serializer,
    const LruParams& lru_params) {
  Status status = EnsureDirectory(dir);
  if (!status.ok()) return status;

  status = ExcludeFromBackups(dir);
  if (!status.ok()) return status;

  StatusOr<std::unique_ptr<DB>> created = OpenDb(dir);
  if (!created.ok()) return created.status();

  std::unique_ptr<DB> db = std::move(created).ValueOrDie();
  LevelDbMigrations::RunMigrations(db.get());

  LevelDbTransaction transaction(db.get(), "Start LevelDB");
  std::set<std::string> users = CollectUserSet(&transaction);
  transaction.Commit();

  // Explicit conversion is required to allow the StatusOr to be created.
  std::unique_ptr<LevelDbPersistence> result(new LevelDbPersistence(
      std::move(db), std::move(dir), std::move(users), serializer, lru_params));
  return std::move(result);
}

LevelDbPersistence::LevelDbPersistence(std::unique_ptr<leveldb::DB> db,
                                       util::Path directory,
                                       std::set<std::string> users,
                                       FSTLocalSerializer* serializer,
                                       const LruParams& lru_params)
    : db_(std::move(db)),
      directory_(std::move(directory)),
      users_(std::move(users)),
      serializer_(serializer) {
  query_cache_ = absl::make_unique<LevelDbQueryCache>(this, serializer_);
  document_cache_ =
      absl::make_unique<LevelDbRemoteDocumentCache>(this, serializer_);
  index_manager_ = absl::make_unique<LevelDbIndexManager>(this);
  reference_delegate_ =
      absl::make_unique<LevelDbLruReferenceDelegate>(this, lru_params);

  // TODO(gsoltis): set up a leveldb transaction for these operations.
  query_cache_->Start();
  reference_delegate_->Start();
  started_ = true;
}

// MARK: - Storage location

#if !defined(__APPLE__)

Path LevelDbPersistence::AppDataDirectory() {
#error "This does not yet support non-Apple platforms."
}

#endif  // !defined(__APPLE__)

util::Path LevelDbPersistence::StorageDirectory(
    const core::DatabaseInfo& database_info, const util::Path& documents_dir) {
  // Use two different path formats:
  //
  //   * persistence_key / project_id . database_id / name
  //   * persistence_key / project_id / name
  //
  // project_ids are DNS-compatible names and cannot contain dots so there's
  // no danger of collisions.
  std::string project_key = database_info.database_id().project_id();
  if (!database_info.database_id().IsDefaultDatabase()) {
    absl::StrAppend(&project_key, ".",
                    database_info.database_id().database_id());
  }

  // Reserve one additional path component to allow multiple physical databases
  return Path::JoinUtf8(documents_dir, database_info.persistence_key(),
                        project_key, "main");
}

// MARK: - Startup

Status LevelDbPersistence::EnsureDirectory(const Path& dir) {
  Status status = util::RecursivelyCreateDir(dir);
  if (!status.ok()) {
    return Status{Error::Internal, "Failed to create persistence directory"}
        .CausedBy(status);
  }

  return Status::OK();
}

#if !defined(__APPLE__)

Status LevelDbPersistence::ExcludeFromBackups(const Path& directory) {
  // Non-Apple platforms don't yet implement exclusion from backups.
  return Status::OK();
}

#endif

StatusOr<std::unique_ptr<DB>> LevelDbPersistence::OpenDb(const Path& dir) {
  leveldb::Options options;
  options.create_if_missing = true;

  DB* database = nullptr;
  leveldb::Status status = DB::Open(options, dir.ToUtf8String(), &database);
  if (!status.ok()) {
    return Status{Error::Internal,
                  StringFormat("Failed to open LevelDB database at %s",
                               dir.ToUtf8String())}
        .CausedBy(ConvertStatus(status));
  }

  return std::unique_ptr<DB>(database);
}

// MARK: - LevelDB utilities

LevelDbTransaction* LevelDbPersistence::current_transaction() {
  HARD_ASSERT(transaction_ != nullptr,
              "Attempting to access transaction before one has started");
  return transaction_.get();
}

util::Status LevelDbPersistence::ClearPersistence(
    const core::DatabaseInfo& database_info) {
  Path leveldb_dir = StorageDirectory(database_info, AppDataDirectory());
  LOG_DEBUG("Clearing persistence for path: %s", leveldb_dir.ToUtf8String());
  return util::RecursivelyDelete(leveldb_dir);
}

int64_t LevelDbPersistence::CalculateByteSize() {
  int64_t count = 0;
  auto iter = util::DirectoryIterator::Create(directory_);
  for (; iter->Valid(); iter->Next()) {
    int64_t file_size = util::FileSize(iter->file()).ValueOrDie();
    count += file_size;
  }

  HARD_ASSERT(iter->status().ok(), "Failed to iterate leveldb directory: %s",
              iter->status().error_message().c_str());
  HARD_ASSERT(count >= 0 && count <= std::numeric_limits<int64_t>::max(),
              "Overflowed counting bytes cached");
  return count;
}

// MARK: - Persistence

model::ListenSequenceNumber LevelDbPersistence::current_sequence_number()
    const {
  return reference_delegate_->current_sequence_number();
}

void LevelDbPersistence::Shutdown() {
  HARD_ASSERT(started_, "FSTLevelDB shutdown without start!");
  started_ = false;
  db_.reset();
}

LevelDbMutationQueue* LevelDbPersistence::GetMutationQueueForUser(
    const auth::User& user) {
  users_.insert(user.uid());
  current_mutation_queue_ =
      absl::make_unique<LevelDbMutationQueue>(user, this, serializer_);
  return current_mutation_queue_.get();
}

LevelDbQueryCache* LevelDbPersistence::query_cache() {
  return query_cache_.get();
}

LevelDbRemoteDocumentCache* LevelDbPersistence::remote_document_cache() {
  return document_cache_.get();
}

LevelDbIndexManager* LevelDbPersistence::index_manager() {
  return index_manager_.get();
}

LevelDbLruReferenceDelegate* LevelDbPersistence::reference_delegate() {
  return reference_delegate_.get();
}

void LevelDbPersistence::RunInternal(absl::string_view label,
                                     std::function<void()> block) {
  HARD_ASSERT(transaction_ == nullptr,
              "Starting a transaction while one is already in progress");

  transaction_ = absl::make_unique<LevelDbTransaction>(db_.get(), label);
  reference_delegate_->OnTransactionStarted(label);

  block();

  reference_delegate_->OnTransactionCommitted();
  transaction_->Commit();
  transaction_.reset();
}

constexpr const char* LevelDbPersistence::kReservedPathComponent;

leveldb::ReadOptions StandardReadOptions() {
  // For now this is paranoid, but perhaps disable that in production builds.
  leveldb::ReadOptions options;
  options.verify_checksums = true;
  return options;
}

}  // namespace local
}  // namespace firestore
}  // namespace firebase
