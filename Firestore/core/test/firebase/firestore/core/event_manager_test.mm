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

#include <memory>
#include <utility>
#include <vector>

#include "Firestore/core/src/firebase/firestore/core/event_manager.h"
#include "Firestore/core/src/firebase/firestore/core/sync_engine.h"
#include "Firestore/core/src/firebase/firestore/core/view_snapshot.h"
#include "Firestore/core/src/firebase/firestore/model/document_key_set.h"
#include "Firestore/core/src/firebase/firestore/model/document_set.h"
#include "Firestore/core/src/firebase/firestore/model/types.h"
#include "Firestore/core/src/firebase/firestore/util/statusor.h"
#include "Firestore/core/test/firebase/firestore/testutil/testutil.h"
#include "gmock/gmock.h"
#include "gtest/gtest.h"

namespace firebase {
namespace firestore {
namespace core {
namespace {

using model::DocumentKeySet;
using model::DocumentSet;
using model::OnlineState;
using util::StatusOr;
using util::StatusOrCallback;
using testutil::Query;
using testing::_;
using testing::ElementsAre;
using testing::StrictMock;

ViewSnapshot::Listener NoopViewSnapshotHandler() {
  return EventListener<ViewSnapshot>::Create(
      [](const StatusOr<ViewSnapshot>&) {});
}

std::shared_ptr<QueryListener> NoopQueryListener(core::Query query) {
  return QueryListener::Create(std::move(query),
                               ListenOptions::DefaultOptions(),
                               NoopViewSnapshotHandler());
}

class MockEventSource : public core::QueryEventSource {
 public:
  MOCK_METHOD1(SetCallback, void(core::SyncEngineCallback*));
  MOCK_METHOD1(Listen, model::TargetId(core::Query));
  MOCK_METHOD1(StopListening, void(const core::Query&));
};

TEST(EventManagerTest, HandlesManyListnersPerQuery) {
  core::Query query = Query("foo/bar");
  auto listener1 = NoopQueryListener(query);
  auto listener2 = NoopQueryListener(query);

  StrictMock<MockEventSource> mock_event_source;
  EXPECT_CALL(mock_event_source, SetCallback(_));
  EventManager event_manager(&mock_event_source);

  EXPECT_CALL(mock_event_source, Listen(query));
  event_manager.AddQueryListener(listener1);

  // Expecting no activity from mock_event_source.
  event_manager.AddQueryListener(listener2);
  event_manager.RemoveQueryListener(listener2);

  EXPECT_CALL(mock_event_source, StopListening(query));
  event_manager.RemoveQueryListener(listener1);
}

TEST(EventManagerTest, HandlesUnlistenOnUnknownListenerGracefully) {
  core::Query query = Query("foo/bar");
  auto listener = NoopQueryListener(query);

  MockEventSource mock_event_source;
  EventManager event_manager(&mock_event_source);

  EXPECT_CALL(mock_event_source, StopListening(_)).Times(0);
  event_manager.RemoveQueryListener(listener);
}

ViewSnapshot make_empty_view_snapshot(const core::Query& query) {
  DocumentSet empty_docs{query.Comparator()};
  // sync_state_changed has to be `true` to prevent an assertion about a
  // meaningless view snapshot.
  return ViewSnapshot{query,
                      empty_docs,
                      empty_docs,
                      {},
                      DocumentKeySet{},
                      false,
                      /*sync_state_changed=*/true,
                      false};
}

TEST(EventManagerTest, NotifiesListenersInTheRightOrder) {
  core::Query query1 = Query("foo/bar");
  core::Query query2 = Query("bar/baz");
  std::vector<std::string> event_order;

  auto listener1 = QueryListener::Create(query1, [&](StatusOr<ViewSnapshot>) {
    event_order.push_back("listener1");
  });
  auto listener2 = QueryListener::Create(query2, [&](StatusOr<ViewSnapshot>) {
    event_order.push_back("listener2");
  });
  auto listener3 = QueryListener::Create(query1, [&](StatusOr<ViewSnapshot>) {
    event_order.push_back("listener3");
  });

  MockEventSource mock_event_source;
  EventManager event_manager(&mock_event_source);

  EXPECT_CALL(mock_event_source, Listen(query1));
  event_manager.AddQueryListener(listener1);

  EXPECT_CALL(mock_event_source, Listen(query2));
  event_manager.AddQueryListener(listener2);

  event_manager.AddQueryListener(listener3);

  ViewSnapshot snapshot1 = make_empty_view_snapshot(query1);
  ViewSnapshot snapshot2 = make_empty_view_snapshot(query2);
  event_manager.OnViewSnapshots({snapshot1, snapshot2});

  ASSERT_THAT(event_order, ElementsAre("listener1", "listener3", "listener2"));
}

TEST(EventManagerTest, WillForwardOnlineStateChanges) {
  core::Query query = Query("foo/bar");

  class FakeQueryListener : public QueryListener {
   public:
    explicit FakeQueryListener(core::Query query)
        : QueryListener(std::move(query),
                        ListenOptions::DefaultOptions(),
                        NoopViewSnapshotHandler()) {
    }

    void OnOnlineStateChanged(OnlineState online_state) override {
      events.push_back(online_state);
    }

    std::vector<OnlineState> events;
  };

  auto fake_listener = std::make_shared<FakeQueryListener>(query);

  MockEventSource mock_event_source;
  EventManager event_manager(&mock_event_source);

  event_manager.AddQueryListener(fake_listener);
  ASSERT_THAT(fake_listener->events, ElementsAre(OnlineState::Unknown));

  event_manager.HandleOnlineStateChange(OnlineState::Online);
  ASSERT_THAT(fake_listener->events,
              ElementsAre(OnlineState::Unknown, OnlineState::Online));
}

}  // namespace
}  // namespace core
}  // namespace firestore
}  // namespace firebase
