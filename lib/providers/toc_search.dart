import 'package:anx_reader/models/search_result_model.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'toc_search.g.dart';

@immutable
class TocSearchState {
  const TocSearchState({
    this.query,
    this.progress = 0.0,
    this.results = const [],
    this.isSearching = false,
  });

  final String? query;
  final double progress;
  final List<SearchResultModel> results;
  final bool isSearching;

  bool get isActive => query != null && query!.isNotEmpty;

  TocSearchState copyWith({
    Object? query = _noValue,
    double? progress,
    List<SearchResultModel>? results,
    bool? isSearching,
  }) {
    return TocSearchState(
      query: identical(query, _noValue) ? this.query : query as String?,
      progress: progress ?? this.progress,
      results: results ?? this.results,
      isSearching: isSearching ?? this.isSearching,
    );
  }
}

const _noValue = Object();

@Riverpod(keepAlive: true)
class TocSearch extends _$TocSearch {
  @override
  TocSearchState build() => const TocSearchState();

  void start(String query) {
    final sanitized = query.trim();
    state = TocSearchState(
      query: sanitized,
      progress: 0.0,
      results: const [],
      isSearching: true,
    );
  }

  void updateProgress(double progress) {
    state = state.copyWith(
      progress: progress,
      isSearching: progress < 1.0,
    );
  }

  void addResult(SearchResultModel result) {
    final updated = List<SearchResultModel>.from(state.results)..add(result);
    state = state.copyWith(
      results: List<SearchResultModel>.unmodifiable(updated),
    );
  }

  void clear() {
    state = const TocSearchState();
  }
}
