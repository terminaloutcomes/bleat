import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class AudiobookshelfAPITests {
    @Test
    func testListeningSessionsUseZeroIndexedPrefixedRouteAndPinnedShape()
        async throws
    {
        let fixture = try APIFixture(responses: [
            HTTPResponse(
                data: try Self.fixture(named: "listening-sessions-page"),
                statusCode: 200
            )
        ])
        let result = try await fixture.api.listeningSessions(page: 0)
        let requests = await fixture.transport.recordedRequests()
        let request = try #require(requests.first)
        let requiredURL1 = try #require(request.url)
        let components = try #require(
            URLComponents(
                url: requiredURL1, resolvingAgainstBaseURL: false
            ))
        #expect(components.path == "/audiobookshelf/api/me/listening-sessions")
        #expect(
            components.queryItems == [
                URLQueryItem(name: "itemsPerPage", value: "500"),
                URLQueryItem(name: "page", value: "0"),
            ])
        #expect(result.value.total == 2)
        #expect(result.value.sessions.count == 1)
        #expect(result.value.sessions.first?.itemID.rawValue == "book-item-1")
        #expect(result.value.sessions.first?.realSeconds == 60)
    }

    @Test
    func testListeningSessionsRootHostedRoute() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: try Self.fixture(named: "listening-sessions-page"),
                    statusCode: 200
                )
            ],
            serverAddress: "https://example.com"
        )
        _ = try await fixture.api.listeningSessions(page: 0)
        let requests = await fixture.transport.recordedRequests()
        #expect(requests.first?.url?.path == "/api/me/listening-sessions")
    }

    @Test
    func testBookDetailUsesNativeAccountAndMapsExpandedContract()
        async throws
    {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Self.expandedBookDetailJSON(),
                    statusCode: 200
                )
            ]
        )

        let result = try await fixture.api.bookDetail(
            for: LibraryItemID(rawValue: "item"),
            in: LibraryID(rawValue: "library")
        )
        let requests = await fixture.transport.recordedRequests()
        let sent = try #require(requests.first)
        let requiredURL2 = try #require(sent.url)
        let components = try #require(
            URLComponents(
                url: requiredURL2,
                resolvingAgainstBaseURL: false
            ))
        let detail = result.value

        #expect(components.path == "/audiobookshelf/api/items/item")
        #expect(
            components.queryItems == [
                URLQueryItem(name: "expanded", value: "1"),
                URLQueryItem(name: "include", value: "progress"),
            ])
        #expect(
            sent.value(forHTTPHeaderField: "Authorization")
                == "Bearer access-token")
        #expect(detail.id == LibraryItemID(rawValue: "item"))
        #expect(detail.libraryID == LibraryID(rawValue: "library"))
        #expect(detail.bookID == BookID(rawValue: "book"))
        #expect(detail.title == "Expanded Book")
        #expect(detail.subtitle == "A Subtitle")
        #expect(
            detail.authors == [
                LibraryBookContributor(
                    id: AuthorID(rawValue: "author")!,
                    name: "An Author"
                )
            ])
        #expect(detail.narrators == ["A Narrator"])
        #expect(
            detail.series == [
                LibraryBookSeries(
                    id: SeriesID(rawValue: "series")!,
                    name: "A Series",
                    sequence: "2"
                )
            ])
        #expect(detail.genres == ["Fiction"])
        #expect(detail.tags == ["Favourite"])
        #expect(detail.descriptionPlain == "Safe description")
        #expect(detail.duration == 120)
        #expect(detail.trackCount == 1)
        #expect(detail.audioFileCount == 1)
        #expect(detail.chapters.count == 2)
        #expect(detail.chapters[1].title == "Second")
        #expect(detail.progress?.userID == UserID(rawValue: "user"))
        #expect(detail.progress?.bookID == BookID(rawValue: "book"))
        #expect(detail.progress?.currentTime == 30)
        #expect(detail.progress?.progress == 0.25)
        #expect(requests.count == 1)
    }

    @Test
    func testBookDetailFailuresRemainTyped() async throws {
        let invalidCases: [(String, String)] = [
            ("\"id\": \"item\"", "\"id\": \"other\""),
            (
                "\"libraryId\": \"library\"",
                "\"libraryId\": \"other\""
            ),
            ("\"mediaType\": \"book\"", "\"mediaType\": \"podcast\""),
            (
                "\"libraryItemId\": \"item\"",
                "\"libraryItemId\": \"other\""
            ),
            ("\"userId\": \"user\"", "\"userId\": \"other\""),
            ("\"mediaItemId\": \"book\"", "\"mediaItemId\": \"other\""),
            ("\"numChapters\": 2", "\"numChapters\": 3"),
            ("\"progress\": 0.25", "\"progress\": 1.25"),
            ("\"numTracks\": 1", "\"numTracks\": 0"),
        ]
        let valid = try #require(
            String(
                data: Self.expandedBookDetailJSON(),
                encoding: .utf8
            ))

        for (target, replacement) in invalidCases {
            let fixture = try APIFixture(
                responses: [
                    HTTPResponse(
                        data: Data(
                            valid.replacingOccurrences(
                                of: target,
                                with: replacement
                            ).utf8
                        ),
                        statusCode: 200
                    )
                ]
            )
            do {
                _ = try await fixture.api.bookDetail(
                    for: LibraryItemID(rawValue: "item"),
                    in: LibraryID(rawValue: "library")
                )
                Issue.record("Expected invalid expanded book detail")
            } catch {
                #expect(error == .invalidBookDetail)
            }
        }

        let malformed = try APIFixture(responses: [
            HTTPResponse(data: Data("{".utf8), statusCode: 200)
        ])
        do {
            _ = try await malformed.api.bookDetail(
                for: LibraryItemID(rawValue: "item"),
                in: LibraryID(rawValue: "library")
            )
            Issue.record("Expected malformed expanded book detail")
        } catch {
            #expect(error == .malformedResponse)
        }

        for (itemID, libraryID, expected) in [
            ("", "library", AudiobookshelfAPIError.invalidLibraryItem),
            ("item", "", AudiobookshelfAPIError.invalidLibrary),
        ] {
            let fixture = try APIFixture(responses: [])
            do {
                _ = try await fixture.api.bookDetail(
                    for: LibraryItemID(rawValue: itemID),
                    in: LibraryID(rawValue: libraryID)
                )
                Issue.record("Expected invalid request identity")
            } catch {
                #expect(error == expected)
            }
            let requests = await fixture.transport.recordedRequests()
            #expect(requests.isEmpty)
        }
    }

    @Test
    func testHomeRequestValidationAndExactQueryContract() throws {
        for limit in [0, 101] {
            if let error = #expect(
                throws: (any Error).self,
                performing: { try LibraryHomeRequest(limit: limit) })
            {
                #expect(error as? LibraryHomeRequestError == .invalidLimit)
            }
        }

        let request = try LibraryHomeRequest(limit: 12)
        #expect(
            request.queryItems == [
                URLQueryItem(name: "limit", value: "12"),
                URLQueryItem(name: "include", value: "progress"),
            ])

        let expandedRequest = try LibraryItemsPageRequest(
            page: 0,
            filter: LibraryItemFilter(
                authorID: try #require(AuthorID(rawValue: "author-1"))),
            collapseSeries: false,
            minified: false
        )
        #expect(
            expandedRequest.queryItems.first { $0.name == "minified" }?.value
                == "0")
        #expect(
            try LibraryHomeRequest(
                limit: 8,
                includeProgress: false
            ).queryItems == [URLQueryItem(name: "limit", value: "8")])
    }

    @Test
    func testPersonalizedShelvesMapOnlyAudioBooksAndExactRoute()
        async throws
    {
        let audioBook = Self.bookItemJSON(
            id: "audio",
            libraryID: "library",
            title: "Audio Book",
            trackCount: 1
        )
        let ebook = Self.bookItemJSON(
            id: "ebook",
            libraryID: "library",
            title: "Ebook",
            trackCount: 0
        )
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        [
                          {
                            "id": "recently-added",
                            "label": "Recently Added",
                            "labelStringKey": "LabelRecentlyAdded",
                            "type": "book",
                            "entities": [\(audioBook), \(ebook)],
                            "total": 2,
                            "futureShelfField": true
                          },
                          {
                            "id": "recent-series",
                            "label": "Recent Series",
                            "type": "series",
                            "entities": [{"id": "series"}],
                            "total": 1
                          },
                          {
                            "id": "read-again",
                            "label": "Read Again",
                            "type": "book",
                            "entities": [\(ebook)],
                            "total": 1
                          }
                        ]
                        """.utf8
                    ),
                    statusCode: 200
                )
            ]
        )
        let request = try LibraryHomeRequest(limit: 10)

        let result = try await fixture.api.personalizedShelves(
            in: LibraryID(rawValue: "library"),
            request: request
        )
        let requests = await fixture.transport.recordedRequests()
        let sent = try #require(requests.first)
        let requiredURL3 = try #require(sent.url)
        let components = try #require(
            URLComponents(
                url: requiredURL3,
                resolvingAgainstBaseURL: false
            ))

        #expect(result.value.count == 1)
        #expect(result.value.first?.id == "recently-added")
        #expect(result.value.first?.label == "Recently Added")
        #expect(
            result.value.first?.labelLocalizationKey == "LabelRecentlyAdded")
        #expect(result.value.first?.total == 2)
        #expect(result.value.first?.items.count == 1)
        #expect(
            result.value.first?.items.first?.id
                == LibraryItemID(rawValue: "audio"))
        #expect(
            components.path
                == "/audiobookshelf/api/libraries/library/personalized")
        #expect(components.queryItems == request.queryItems)
        #expect(
            sent.value(forHTTPHeaderField: "Authorization")
                == "Bearer access-token")
    }

    @Test
    func testContinueListeningLoadsTenItemsWithoutProgressRequests()
        async throws
    {
        let items = (0..<10).map { index in
            Self.bookItemJSON(
                id: "item-\(index)", libraryID: "library",
                title: "Book \(index)", trackCount: 1)
        }.joined(separator: ",")
        let response = HTTPResponse(
            data: Data(
                """
                [{"id":"continue-listening","label":"Continue Listening",
                  "type":"book","entities":[\(items)],"total":10}]
                """.utf8), statusCode: 200)
        for prefix in ["", "/audiobookshelf"] {
            let path = "\(prefix)/api/libraries/library/personalized"
            let fixture = try APIFixture(
                responsesByPath: [path: [response, response]],
                serverAddress: "https://example.com\(prefix)")
            for _ in 0..<2 {
                let result = try await fixture.api.personalizedShelves(
                    in: LibraryID(rawValue: "library"),
                    request: try LibraryHomeRequest(limit: 10))
                #expect(
                    result.value.first?.items.map(\.id.rawValue)
                        == (0..<10).map { "item-\($0)" })
            }
            let requests = await fixture.transport.recordedRequests()
            #expect(requests.compactMap { $0.url?.path } == [path, path])
        }
    }

    @Test
    func testPersonalizedShelfFailuresRemainTyped() async throws {
        let book = Self.bookItemJSON(
            id: "book",
            libraryID: "library",
            title: "Book",
            trackCount: 1
        )
        let cases: [Data] = [
            Data(
                """
                [{"id":"continue-listening","label":"Continue Listening",
                  "type":"book","entities":[\(book),\(book)],"total":2}]
                """.utf8),
            Data("{\"not\":\"an array\"}".utf8),
            Data(
                """
                [{
                  "id": "broken",
                  "label": "Broken",
                  "type": "book",
                  "entities": [\(book)],
                  "total": -1
                }]
                """.utf8
            ),
            Data(
                """
                [
                  {
                    "id": "duplicate",
                    "label": "First",
                    "type": "book",
                    "entities": [\(book)],
                    "total": 1
                  },
                  {
                    "id": "duplicate",
                    "label": "Second",
                    "type": "book",
                    "entities": [\(book)],
                    "total": 1
                  }
                ]
                """.utf8
            ),
        ]
        let expected: [AudiobookshelfAPIError] = [
            .invalidPersonalizedShelves,
            .malformedResponse,
            .invalidPersonalizedShelves,
            .invalidPersonalizedShelves,
        ]
        let request = try LibraryHomeRequest(limit: 10)
        for (data, expectedError) in zip(cases, expected) {
            let fixture = try APIFixture(
                responses: [
                    HTTPResponse(data: data, statusCode: 200)
                ]
            )
            do {
                _ = try await fixture.api.personalizedShelves(
                    in: LibraryID(rawValue: "library"),
                    request: request
                )
                Issue.record("Expected typed personalized-shelf failure")
            } catch {
                #expect(error == expectedError)
            }
        }

        let fixture = try APIFixture(responses: [])
        let defaultRequest = try LibraryHomeRequest()
        do {
            _ = try await fixture.api.personalizedShelves(
                in: LibraryID(rawValue: ""),
                request: defaultRequest
            )
            Issue.record("Expected invalid library")
        } catch {
            #expect(error == .invalidLibrary)
        }
        let requests = await fixture.transport.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test
    func testSearchRequestValidationAndExactQueryContract() throws {
        for query in [
            "", " \n ", "bad\nquery", String(repeating: "a", count: 201),
        ] {
            if let error = #expect(
                throws: (any Error).self,
                performing: { try LibrarySearchRequest(query: query) })
            {
                #expect(error as? LibrarySearchRequestError == .invalidQuery)
            }
        }
        for limit in [0, 101] {
            if let error = #expect(
                throws: (any Error).self,
                performing: {
                    try LibrarySearchRequest(
                        query: "book",
                        limit: limit
                    )
                })
            {
                #expect(error as? LibrarySearchRequestError == .invalidLimit)
            }
        }

        let request = try LibrarySearchRequest(
            query: "  one & two  ",
            limit: 12
        )
        #expect(request.query == "one & two")
        #expect(
            request.queryItems == [
                URLQueryItem(name: "q", value: "one & two"),
                URLQueryItem(name: "limit", value: "12"),
            ])
    }

    @Test
    func testSearchMapsExpandedBookMatchesAndExactRoute() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Self.searchJSON(
                        itemLibraryID: "library",
                        bookCount: 1
                    ),
                    statusCode: 200
                )
            ]
        )
        let request = try LibrarySearchRequest(
            query: "First Book",
            limit: 12
        )

        let result = try await fixture.api.search(
            in: LibraryID(rawValue: "library"),
            request: request
        )
        let requests = await fixture.transport.recordedRequests()
        let sent = try #require(requests.first)
        let requiredURL4 = try #require(sent.url)
        let queryItems = try #require(
            URLComponents(
                url: requiredURL4,
                resolvingAgainstBaseURL: false
            )?.queryItems)

        #expect(result.value.books.count == 1)
        #expect(
            result.value.books.first?.id
                == LibraryItemID(rawValue: "search-item-0"))
        #expect(result.value.books.first?.title == "Search Book 0")
        #expect(
            result.value.books.first?.libraryID
                == LibraryID(rawValue: "library"))
        #expect(
            sent.url?.path == "/audiobookshelf/api/libraries/library/search")
        #expect(queryItems == request.queryItems)
    }

    @Test
    func testSearchMapsTypedAuthorAndSeriesGroups() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "book": [],
                          "authors": [{"id": "author-1", "name": "First Author"}],
                          "series": [{
                            "series": {
                              "id": "series-1",
                              "name": "First Series"
                            },
                            "books": []
                          }]
                        }
                        """.utf8
                    ),
                    statusCode: 200
                )
            ]
        )
        let request = try LibrarySearchRequest(query: "first", limit: 5)

        let result = try await fixture.api.search(
            in: LibraryID(rawValue: "library"),
            request: request
        )

        #expect(result.value.books == [])
        #expect(
            result.value.authors == [
                LibrarySearchAuthorMatch(
                    id: try #require(AuthorID(rawValue: "author-1")),
                    name: "First Author"
                )
            ])
        #expect(
            result.value.series == [
                LibrarySearchSeriesMatch(
                    id: try #require(SeriesID(rawValue: "series-1")),
                    name: "First Series"
                )
            ])
    }

    @Test
    func testSearchFailuresRemainTyped() async throws {
        let request = try LibrarySearchRequest(
            query: "book",
            limit: 1
        )
        let cases: [(Data, AudiobookshelfAPIError)] = [
            (
                Data("{\"authors\":[]}".utf8),
                .malformedResponse
            ),
            (
                Self.searchJSON(
                    itemLibraryID: "library",
                    bookCount: 2
                ),
                .invalidSearchResults
            ),
            (
                Self.searchJSON(
                    itemLibraryID: "other",
                    bookCount: 1
                ),
                .invalidLibraryItem
            ),
        ]
        for (data, expectedError) in cases {
            let fixture = try APIFixture(
                responses: [
                    HTTPResponse(data: data, statusCode: 200)
                ]
            )
            do {
                _ = try await fixture.api.search(
                    in: LibraryID(rawValue: "library"),
                    request: request
                )
                Issue.record("Expected typed search failure")
            } catch {
                #expect(error == expectedError)
            }
        }

        let fixture = try APIFixture(responses: [])
        do {
            _ = try await fixture.api.search(
                in: LibraryID(rawValue: ""),
                request: request
            )
            Issue.record("Expected invalid library")
        } catch {
            #expect(error == .invalidLibrary)
        }
        let sent = await fixture.transport.recordedRequests()
        #expect(sent.isEmpty)
    }

    @Test
    func testPageRequestValidationAndExactQueryContract() throws {
        if let error = #expect(
            throws: (any Error).self,
            performing: { try LibraryItemsPageRequest(page: -1) })
        {
            #expect(error as? LibraryPageRequestError == .invalidPage)
        }
        for limit in [0, 101] {
            if let error = #expect(
                throws: (any Error).self,
                performing: {
                    try LibraryItemsPageRequest(page: 0, limit: limit)
                })
            {
                #expect(error as? LibraryPageRequestError == .invalidLimit)
            }
        }
        if let error = #expect(
            throws: (any Error).self,
            performing: { try LibraryItemFilter("bad\nfilter") })
        {
            #expect(error as? LibraryPageRequestError == .invalidFilter)
        }

        let filter = try LibraryItemFilter("genres.Fiction & Fantasy")
        let request = try LibraryItemsPageRequest(
            page: 2,
            limit: 50,
            sort: .author,
            descending: true,
            filter: filter
        )
        #expect(
            request.queryItems == [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "page", value: "2"),
                URLQueryItem(
                    name: "sort",
                    value: "media.metadata.authorNameLF"
                ),
                URLQueryItem(name: "desc", value: "1"),
                URLQueryItem(
                    name: "filter",
                    value: "genres.Fiction & Fantasy"
                ),
                URLQueryItem(name: "minified", value: "1"),
                URLQueryItem(name: "collapseseries", value: "1"),
                URLQueryItem(name: "include", value: "progress"),
            ])

        let sortValues = try [
            LibraryItemSort.title,
            .author,
            .addedAt,
            .updatedAt,
            .duration,
            .sequence,
        ].map {
            try LibraryItemsPageRequest(
                page: 0,
                sort: $0,
                includeProgress: false,
                collapseSeries: false
            ).queryItems
                .first { $0.name == "sort" }?
                .value
        }
        #expect(
            sortValues == [
                "media.metadata.title",
                "media.metadata.authorNameLF",
                "addedAt",
                "updatedAt",
                "media.duration",
                "sequence",
            ])
        #expect(
            LibraryProgressFilter.allCases.map {
                LibraryItemFilter(progress: $0).rawValue
            } == [
                "progress.ZmluaXNoZWQ=",
                "progress.aW4tcHJvZ3Jlc3M=",
                "progress.bm90LXN0YXJ0ZWQ=",
                "progress.bm90LWZpbmlzaGVk",
            ])
        #expect(
            LibraryItemFilter(
                authorID: try #require(AuthorID(rawValue: "author-1"))
            ).rawValue == "authors.YXV0aG9yLTE=")
        #expect(
            LibraryItemFilter(
                seriesID: try #require(SeriesID(rawValue: "series-1"))
            ).rawValue == "series.c2VyaWVzLTE=")
    }

    @Test
    func testLibraryItemsMapsPinnedFixtureAndPagination() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: try Self.fixture(
                        named: "library-items-minified"
                    ),
                    statusCode: 200
                )
            ]
        )
        let request = try LibraryItemsPageRequest(
            page: 0,
            limit: 2,
            descending: true
        )

        let result = try await fixture.api.libraryItems(
            in: LibraryID(rawValue: "library"),
            request: request
        )
        let recordedRequests =
            await fixture.transport.recordedRequests()
        let sent = try #require(recordedRequests.first)
        let requiredURL5 = try #require(sent.url)
        let queryItems = try #require(
            URLComponents(
                url: requiredURL5,
                resolvingAgainstBaseURL: false
            )?.queryItems)

        #expect(result.value.total == 3)
        #expect(result.value.page == 0)
        #expect(result.value.limit == 2)
        #expect(result.value.hasNextPage)
        #expect(result.value.items.count == 2)
        let first = result.value.items[0]
        #expect(first.id == LibraryItemID(rawValue: "item-one"))
        #expect(first.libraryID == LibraryID(rawValue: "library"))
        #expect(first.title == "The First Book")
        #expect(first.subtitle == nil)
        #expect(first.authorName == "First Author")
        #expect(first.narratorName == nil)
        #expect(first.seriesName == "A Series #1")
        #expect(first.genres == ["Fiction"])
        #expect(first.publisher == nil)
        #expect(first.publishedYear == "2024")
        #expect(first.duration == 7200.5)
        #expect(first.trackCount == 2)
        #expect(first.chapterCount == 4)
        #expect(!(first.isExplicit))
        #expect(!(first.isAbridged))
        #expect(result.value.items[1].title == "Second Book")
        #expect(result.value.items[1].isExplicit)
        #expect(result.value.items[1].isAbridged)
        #expect(sent.url?.path == "/audiobookshelf/api/libraries/library/items")
        #expect(queryItems == request.queryItems)
    }

    @Test
    func testLibraryItemsMapsCollapsedSeriesBrowseEntry() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "results": [{
                            "id": "item-1",
                            "libraryId": "library",
                            "addedAt": 1,
                            "updatedAt": 2,
                            "mediaType": "book",
                            "collapsedSeries": {
                              "id": "series-1",
                              "name": "A Series",
                              "numBooks": 2,
                              "seriesSequenceList": "1, 2"
                            },
                            "media": {
                              "metadata": {
                                "title": "A Series Volume One",
                                "authorName": "First Author",
                                "seriesName": "A Series #1",
                                "genres": [],
                                "explicit": false,
                                "abridged": false
                              },
                              "numTracks": 1,
                              "numChapters": 1,
                              "duration": 60
                            }
                          }],
                          "total": 1,
                          "limit": 1,
                          "page": 0
                        }
                        """.utf8
                    ),
                    statusCode: 200
                )
            ]
        )
        let request = try LibraryItemsPageRequest(page: 0, limit: 1)

        let result = try await fixture.api.libraryItems(
            in: LibraryID(rawValue: "library"),
            request: request
        )
        let entry = try #require(result.value.browseEntries.first)
        guard
            case .series(let series, representative: let representative) = entry
        else {
            Issue.record("Expected a collapsed series browse entry")
            return
        }
        #expect(series.id == (try #require(SeriesID(rawValue: "series-1"))))
        #expect(series.name == "A Series")
        #expect(series.numBooks == 2)
        #expect(series.sequenceList == ["1, 2"])
        #expect(representative.id == LibraryItemID(rawValue: "item-1"))
    }

    @Test
    func testSeriesFilteredExpandedPageMapsTheMatchingSequence() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "results": [{
                            "id": "item-1",
                            "libraryId": "library",
                            "addedAt": 1,
                            "updatedAt": 2,
                            "mediaType": "book",
                            "media": {
                              "metadata": {
                                "title": "A Series Volume One",
                                "authorName": "First Author",
                                "seriesName": "A Series",
                                "series": {
                                  "id": "series-1",
                                  "name": "A Series",
                                  "sequence": "1"
                                },
                                "genres": [],
                                "explicit": false,
                                "abridged": false
                              },
                              "numTracks": 1,
                              "numChapters": 1,
                              "duration": 60
                            }
                          }],
                          "total": 1,
                          "limit": 1,
                          "page": 0
                        }
                        """.utf8
                    ),
                    statusCode: 200
                )
            ]
        )
        let seriesID = try #require(SeriesID(rawValue: "series-1"))
        let request = try LibraryItemsPageRequest(
            page: 0,
            limit: 1,
            sort: .sequence,
            filter: LibraryItemFilter(seriesID: seriesID),
            collapseSeries: false,
            minified: false
        )

        let result = try await fixture.api.libraryItems(
            in: LibraryID(rawValue: "library"),
            request: request
        )

        #expect(
            result.value.items.first?.series == [
                LibraryBookSeries(
                    id: seriesID,
                    name: "A Series",
                    sequence: "1"
                )
            ])
    }

    @Test
    func testLibraryItemPageAndItemFailuresRemainTyped() async throws {
        let invalidCases: [(Data, AudiobookshelfAPIError)] = [
            (
                Self.pageJSON(
                    total: -1,
                    limit: 1,
                    page: 0,
                    itemLibraryID: "library"
                ),
                .invalidPage
            ),
            (
                Self.pageJSON(
                    total: 1,
                    limit: 2,
                    page: 0,
                    itemLibraryID: "library"
                ),
                .invalidPage
            ),
            (
                Self.pageJSON(
                    total: 1,
                    limit: 1,
                    page: 0,
                    itemLibraryID: "other"
                ),
                .invalidLibraryItem
            ),
            (
                Self.pageJSON(
                    total: 1,
                    limit: 1,
                    page: 0,
                    itemLibraryID: "library",
                    mediaType: "podcast"
                ),
                .invalidLibraryItem
            ),
        ]

        for (data, expectedError) in invalidCases {
            let fixture = try APIFixture(
                responses: [
                    HTTPResponse(data: data, statusCode: 200)
                ]
            )
            let request = try LibraryItemsPageRequest(
                page: 0,
                limit: 1
            )
            do {
                _ = try await fixture.api.libraryItems(
                    in: LibraryID(rawValue: "library"),
                    request: request
                )
                Issue.record("Expected invalid page or item")
            } catch {
                #expect(error == expectedError)
            }
        }

        let fixture = try APIFixture(responses: [])
        let request = try LibraryItemsPageRequest(page: 0)
        do {
            _ = try await fixture.api.libraryItems(
                in: LibraryID(rawValue: ""),
                request: request
            )
            Issue.record("Expected invalid library")
        } catch {
            #expect(error == .invalidLibrary)
        }
        let recordedRequests =
            await fixture.transport.recordedRequests()
        #expect(recordedRequests.isEmpty)
    }

    @Test
    func testLibrariesUsesNativeAccountAndMapsForwardCompatibleDTOs()
        async throws
    {
        let response = HTTPResponse(
            data: Data(
                """
                {
                  "libraries": [
                    {
                      "id": "books",
                      "name": "Audiobooks",
                      "mediaType": "book",
                      "unknownFutureField": true
                    },
                    {
                      "id": "future",
                      "name": "Future Media",
                      "mediaType": "spoken-word-v2"
                    }
                  ],
                  "unknownEnvelopeField": 123
                }
                """.utf8
            ),
            statusCode: 200
        )
        let fixture = try APIFixture(responses: [response])

        let result = try await fixture.api.libraries()
        let requests = await fixture.transport.recordedRequests()
        let request = try #require(requests.first)
        let correlationHeader = try #require(
            request.value(forHTTPHeaderField: "X-Bleat-Request-ID"))

        #expect(
            result.value == [
                LibrarySummary(
                    id: LibraryID(rawValue: "books"),
                    name: "Audiobooks",
                    mediaType: .book
                ),
                LibrarySummary(
                    id: LibraryID(rawValue: "future"),
                    name: "Future Media",
                    mediaType: .unknown("spoken-word-v2")
                ),
            ])
        #expect(
            request.url?.absoluteString
                == "https://example.com/audiobookshelf/api/libraries")
        #expect(request.httpMethod == "GET")
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer access-token")
        #expect(
            UUID(uuidString: correlationHeader) == result.correlationID.rawValue
        )
        #expect(requests.count == 1)
    }

    @Test
    func testLibraryFailuresRemainTyped() async throws {
        let cases: [(HTTPResponse, AudiobookshelfAPIError)] = [
            (
                HTTPResponse(data: Data(), statusCode: 503),
                .unexpectedStatus(503)
            ),
            (
                HTTPResponse(
                    data: Data("{\"libraries\":".utf8),
                    statusCode: 200
                ),
                .malformedResponse
            ),
            (
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "libraries": [{
                            "id": "",
                            "name": "Broken",
                            "mediaType": "book"
                          }]
                        }
                        """.utf8
                    ),
                    statusCode: 200
                ),
                .invalidLibrary
            ),
            (
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "libraries": [{
                            "id": "library",
                            "name": "   ",
                            "mediaType": "book"
                          }]
                        }
                        """.utf8
                    ),
                    statusCode: 200
                ),
                .invalidLibrary
            ),
        ]

        for (response, expectedError) in cases {
            let fixture = try APIFixture(responses: [response])
            do {
                _ = try await fixture.api.libraries()
                Issue.record("Expected typed API failure")
            } catch {
                #expect(error == expectedError)
            }
        }
    }

    @Test
    func testMissingCredentialsRemainTyped() async throws {
        let fixture = try APIFixture(
            responses: [],
            includeCredentials: false
        )

        do {
            _ = try await fixture.api.libraries()
            Issue.record("Expected missing credentials")
        } catch {
            #expect(error == .authentication(.missingCredentials))
        }
        let requests = await fixture.transport.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test
    func testCancellationRemainsTypedAndSendsNoRequest() async throws {
        let fixture = try APIFixture(responses: [])
        let task = Task {
            try await fixture.api.libraries()
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error as? AudiobookshelfAPIError == .cancelled)
        }
        let requests = await fixture.transport.recordedRequests()
        #expect(requests.isEmpty)
    }

    private static func fixture(named name: String) throws -> Data {
        let url = try #require(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: nil
            )?.first {
                $0.lastPathComponent == "\(name).json"
            })
        return try Data(contentsOf: url)
    }

    private static func pageJSON(
        total: Int,
        limit: Int,
        page: Int,
        itemLibraryID: String,
        mediaType: String = "book"
    ) -> Data {
        Data(
            """
            {
              "results": [{
                "id": "item",
                "libraryId": "\(itemLibraryID)",
                "addedAt": 1,
                "updatedAt": 2,
                "mediaType": "\(mediaType)",
                "media": {
                  "metadata": {
                    "title": "Book",
                    "genres": [],
                    "explicit": false,
                    "abridged": false
                  },
                  "numTracks": 1,
                  "numChapters": 0,
                  "duration": 60
                }
              }],
              "total": \(total),
              "limit": \(limit),
              "page": \(page)
            }
            """.utf8
        )
    }

    private static func searchJSON(
        itemLibraryID: String,
        bookCount: Int
    ) -> Data {
        let matches = (0..<bookCount).map { index in
            """
            {
              "libraryItem": {
                "id": "search-item-\(index)",
                "libraryId": "\(itemLibraryID)",
                "addedAt": 1,
                "updatedAt": 2,
                "mediaType": "book",
                "media": {
                  "metadata": {
                    "title": "Search Book \(index)",
                    "authorName": "",
                    "narratorName": "",
                    "seriesName": "",
                    "genres": [],
                    "explicit": false,
                    "abridged": false
                  },
                  "numTracks": 1,
                  "numChapters": 0,
                  "duration": 60,
                  "futureExpandedField": true
                },
                "futureExpandedField": true
              }
            }
            """
        }.joined(separator: ",")
        return Data(
            """
            {
              "book": [\(matches)],
              "narrators": [],
              "tags": [],
              "genres": [],
              "series": [],
              "authors": [],
              "futureCategory": []
            }
            """.utf8
        )
    }

    private static func bookItemJSON(
        id: String,
        libraryID: String,
        title: String,
        trackCount: Int
    ) -> String {
        """
        {
          "id": "\(id)",
          "libraryId": "\(libraryID)",
          "addedAt": 1,
          "updatedAt": 2,
          "mediaType": "book",
          "media": {
            "metadata": {
              "title": "\(title)",
              "genres": [],
              "explicit": false,
              "abridged": false
            },
            "numTracks": \(trackCount),
            "numChapters": 0,
            "duration": 60
          }
        }
        """
    }

    private static func expandedBookDetailJSON() -> Data {
        Data(
            """
            {
              "id": "item",
              "libraryId": "library",
              "addedAt": 1000,
              "updatedAt": 2000,
              "mediaType": "book",
              "media": {
                "id": "book",
                "libraryItemId": "item",
                "metadata": {
                  "title": "Expanded Book",
                  "subtitle": "A Subtitle",
                  "authors": [{"id": "author", "name": "An Author"}],
                  "narrators": ["A Narrator"],
                  "series": [{
                    "id": "series",
                    "name": "A Series",
                    "sequence": "2"
                  }],
                  "genres": ["Fiction"],
                  "publishedYear": "2024",
                  "publishedDate": "2024-01-02",
                  "publisher": "A Publisher",
                  "description": "<p>Safe description</p>",
                  "descriptionPlain": "Safe description",
                  "isbn": "9780000000000",
                  "asin": "B000000000",
                  "language": "English",
                  "explicit": false,
                  "abridged": false,
                  "futureMetadataField": true
                },
                "tags": ["Favourite"],
                "numTracks": 1,
                "numAudioFiles": 1,
                "numChapters": 2,
                "duration": 120,
                "chapters": [
                  {"id": 0, "start": 0, "end": 60, "title": "First"},
                  {"id": 1, "start": 60, "end": 120, "title": "Second"}
                ],
                "tracks": [{
                  "index": 1,
                  "startOffset": 0,
                  "duration": 120,
                  "title": "book.m4b",
                  "contentUrl": "/api/items/item/file/inode",
                  "mimeType": "audio/mp4"
                }],
                "futureMediaField": true
              },
              "userMediaProgress": {
                "id": "progress",
                "userId": "user",
                "libraryItemId": "item",
                "episodeId": null,
                "mediaItemId": "book",
                "mediaItemType": "book",
                "duration": 120,
                "progress": 0.25,
                "currentTime": 30,
                "isFinished": false,
                "hideFromContinueListening": false,
                "ebookLocation": null,
                "ebookProgress": 0,
                "lastUpdate": 3000,
                "startedAt": 1000,
                "finishedAt": null
              },
              "futureItemField": true
            }
            """.utf8
        )
    }
}

private struct APIFixture {
    let transport: APIScriptTransport
    let api: AudiobookshelfAPI<APIScriptTransport, APICredentialStore>

    init(
        responses: [HTTPResponse] = [],
        responsesByPath: [String: [HTTPResponse]] = [:],
        includeCredentials: Bool = true,
        serverAddress: String = "https://example.com/audiobookshelf"
    ) throws {
        transport = APIScriptTransport(
            responses: responses,
            responsesByPath: responsesByPath
        )
        let credentials = APICredentialStore(
            credentials: includeCredentials
                ? try AuthenticationTokens(
                    accessToken: "access-token",
                    refreshToken: "refresh-token"
                )
                : nil
        )
        let account = try ServerAccount(
            id: AccountID(rawValue: "account"),
            server: NormalizedServerURL(serverAddress),
            serverVersion: "2.36.0",
            authenticationMethods: [.local],
            user: AuthenticatedUser(
                id: UserID(rawValue: "user"),
                username: "reader",
                type: .user,
                permissions: UserPermissions(
                    download: true,
                    update: false,
                    delete: false,
                    upload: false,
                    createEReader: false,
                    accessAllLibraries: true,
                    accessAllTags: true,
                    accessExplicitContent: true,
                    selectedTagsNotAccessible: false
                ),
                accessibleLibraryIDs: [],
                selectedItemTags: []
            )
        )
        api = AudiobookshelfAPI(
            account: account,
            authCoordinator: AuthCoordinator(
                transport: transport,
                credentialStore: credentials
            )
        )
    }
}

private actor APICredentialStore: AccountCredentialStore {
    private var stored: AuthenticationTokens?

    init(credentials: AuthenticationTokens?) {
        stored = credentials
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        stored
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        stored = credentials
    }

    func deleteCredentials(for accountID: AccountID) {
        stored = nil
    }
}

private actor APIScriptTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var responsesByPath: [String: [HTTPResponse]]
    private var requests: [URLRequest] = []

    init(
        responses: [HTTPResponse],
        responsesByPath: [String: [HTTPResponse]] = [:]
    ) {
        self.responses = responses
        self.responsesByPath = responsesByPath
    }

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
        try Task.checkCancellation()
        requests.append(request)
        if let path = request.url?.path,
            var pathResponses = responsesByPath[path],
            !pathResponses.isEmpty
        {
            let response = pathResponses.removeFirst()
            responsesByPath[path] = pathResponses
            return response
        }
        guard !responses.isEmpty else {
            throw APITestError.missingResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

}

private enum APITestError: Error {
    case missingResponse
}
