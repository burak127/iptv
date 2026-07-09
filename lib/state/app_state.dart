import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/category.dart';
import '../models/iptv_source.dart';
import '../models/live_channel.dart';
import '../models/media_item.dart';
import '../models/movie.dart';
import '../models/series.dart';
import '../services/iptv_errors.dart';
import '../services/iptv_repository.dart';
import '../services/progress_repository.dart';
import '../services/source_repository.dart';
import '../services/xtream_client.dart';

/// Sentinel category id for the pinned "Favorites" filter.
const String kFavoritesCategoryId = '__favorites__';

/// Central app state. Holds the sources, the active source, and per-content-type
/// slices (live / vod / series) each with a precomputed category index, plus
/// cross-cutting favorites, recents and resume. Uses a generation token so a
/// slow load can't overwrite state after the user switched source.
class AppState extends ChangeNotifier {
  AppState({
    SourceRepository? sourceRepository,
    IptvRepository? repository,
    ProgressRepository? progressRepository,
  })  : _sourceRepo = sourceRepository ?? SourceRepository(),
        _repo = repository ?? IptvRepository(),
        _progress = progressRepository ?? ProgressRepository();

  final SourceRepository _sourceRepo;
  final IptvRepository _repo;
  final ProgressRepository _progress;

  bool initialized = false;
  // Per-slice generation tokens: a live/vod/series load may run concurrently
  // (the Search tab warms vod+series back-to-back) — a shared counter would
  // cancel one with the other and leave its loading flag stuck forever.
  int _liveGen = 0;
  int _vodGen = 0;
  int _seriesGen = 0;

  // Sources
  List<IptvSource> sources = [];
  IptvSource? active;
  bool get hasActive => active != null;
  bool get activeIsXtream => active?.isXtream ?? false;

  // Live
  List<IptvCategory> liveCategories = [];
  List<LiveChannel> channels = [];
  Map<String, List<LiveChannel>> _liveByCat = {};
  String? liveCategoryId;

  /// Id of the last live channel the user watched (for "resume last channel").
  String? lastLiveChannelId;

  /// Category the last-watched channel was being watched FROM (null = "Alle
  /// kanaler", [kFavoritesCategoryId] = Favoritter) -- so "resume last
  /// channel" can rebuild the same filtered playlist the user actually had
  /// open (and therefore the same next/prev zap order), instead of always
  /// falling back to the full unfiltered channel list.
  String? lastLiveCategoryId;

  /// One-shot guard so the auto-resume only fires once per app launch.
  bool autoResumedThisSession = false;
  bool liveLoading = false;
  String? liveError;
  IptvErrorAction liveErrorAction = IptvErrorAction.retry;
  List<String> _liveCategoryOrder = []; // user-chosen category id order
  Set<String> _hiddenLiveCategories = {}; // user-hidden category ids
  Set<String> _hiddenVodCategories = {};
  Set<String> _hiddenSeriesCategories = {};

  /// Xtream account expiry — drives the "udløber snart" warning banner.
  DateTime? accountExpiry;

  // VOD
  List<IptvCategory> vodCategories = [];
  List<Movie> movies = [];
  Map<String, List<Movie>> _vodByCat = {};
  String? vodCategoryId;
  bool vodLoaded = false;
  bool vodLoading = false;
  String? vodError;

  // Series
  List<IptvCategory> seriesCategories = [];
  List<Series> series = [];
  Map<String, List<Series>> _seriesByCat = {};
  String? seriesCategoryId;
  bool seriesLoaded = false;
  bool seriesLoading = false;
  String? seriesError;

  // Cross-cutting
  Set<String> _favorites = {};
  List<RecentEntry> recents = [];

  // Parental gate: when a PIN is set, adult-flagged categories (and their
  // content) are hidden everywhere until the PIN is entered for the session.
  bool _pinSet = false;
  bool _adultUnlocked = false;
  bool get hasParentalPin => _pinSet;
  bool get adultLocked => _pinSet && !_adultUnlocked;

  static const List<String> _adultMarkers = [
    'xxx', 'porn', 'adult', '+18', '18+', 'x-rated', 'erotic', 'erotik',
    'voksen', // Danish "adult"
  ];

  /// Conservative name heuristic — only unambiguous markers, so legitimate
  /// categories are never hidden by accident.
  static bool isAdultCategoryName(String name) {
    final n = name.toLowerCase();
    return _adultMarkers.any(n.contains);
  }

  bool _isAdultCat(IptvCategory c) => isAdultCategoryName(c.name);

  Set<String> _adultIdsOf(List<IptvCategory> cats) =>
      {for (final c in cats) if (_isAdultCat(c)) c.id};

  List<IptvCategory> _gateCats(List<IptvCategory> cats) =>
      adultLocked ? cats.where((c) => !_isAdultCat(c)).toList() : cats;

  /// Reload whether a PIN exists (after create/remove in Settings).
  Future<void> refreshParentalPin() async {
    _pinSet = await _progress.hasPin();
    if (!_pinSet) _adultUnlocked = false;
    notifyListeners();
  }

  /// Unlock adult content for this session; false on a wrong PIN.
  Future<bool> unlockAdult(String pin) async {
    if (await _progress.checkPin(pin)) {
      _adultUnlocked = true;
      notifyListeners();
      return true;
    }
    return false;
  }

  void lockAdult() {
    if (_adultUnlocked) {
      _adultUnlocked = false;
      notifyListeners();
    }
  }

  // ---------------- lifecycle ----------------
  Future<void> init() async {
    _pinSet = await _progress.hasPin();
    sources = await _sourceRepo.loadSources();
    final activeId = await _sourceRepo.loadActiveId();
    active = _firstWhereOrNull(sources, (s) => s.id == activeId) ??
        (sources.isNotEmpty ? sources.first : null);
    initialized = true;
    notifyListeners();
    if (active != null) await _loadForActive();
  }

  Future<void> _loadForActive() async {
    final s = active;
    if (s == null) return;
    _favorites = await _progress.favorites(s.id);
    recents = await _progress.recents(s.id);
    _liveCategoryOrder = await _progress.categoryOrder(s.id);
    _hiddenLiveCategories = await _progress.hiddenCategories(s.id);
    _hiddenVodCategories =
        await _progress.hiddenCategories(s.id, kind: 'vod');
    _hiddenSeriesCategories =
        await _progress.hiddenCategories(s.id, kind: 'series');
    await loadLive();
    // Fetch expiry in the background for the warning banner (Xtream only).
    if (s.isXtream) {
      accountInfo().then((info) {
        if (info != null && active?.id == s.id) {
          accountExpiry = info.expiry;
          notifyListeners();
        }
      });
    }
  }

  /// Days until the account expires, or null when unknown/far out.
  int? get expiryDaysLeft {
    final e = accountExpiry;
    if (e == null) return null;
    final days = e.difference(DateTime.now().toUtc()).inDays;
    return days <= 7 ? days : null;
  }

  // ---------------- source management ----------------
  Future<void> addSource(IptvSource source, {bool activate = true}) async {
    sources = [...sources, source];
    await _sourceRepo.saveSources(sources);
    if (activate) {
      await setActive(source);
    } else {
      notifyListeners();
    }
  }

  Future<void> updateSource(IptvSource source) async {
    sources = [for (final s in sources) if (s.id == source.id) source else s];
    await _sourceRepo.saveSources(sources);
    if (active?.id == source.id) {
      active = source;
      await loadLive(forceRefresh: true);
    } else {
      notifyListeners();
    }
  }

  Future<void> removeSource(IptvSource source) async {
    sources = sources.where((s) => s.id != source.id).toList();
    await _sourceRepo.saveSources(sources);
    // Purge everything persisted for this source — cached catalogs are tens of
    // MB and favorites/resume keys would otherwise leak forever.
    await _repo.purgeSource(source.id);
    await _progress.purgeSource(source.id);
    if (active?.id == source.id) {
      active = sources.isNotEmpty ? sources.first : null;
      await _sourceRepo.saveActiveId(active?.id);
      _resetContent();
      if (active != null) {
        await _loadForActive();
      } else {
        notifyListeners();
      }
    } else {
      notifyListeners();
    }
  }

  Future<void> setActive(IptvSource source) async {
    active = source;
    await _sourceRepo.saveActiveId(source.id);
    _resetContent();
    await _loadForActive();
  }

  void _resetContent() {
    // Cancel ALL in-flight loads — they belong to the previous source.
    _liveGen++;
    _vodGen++;
    _seriesGen++;
    liveCategories = [];
    channels = [];
    _liveByCat = {};
    liveCategoryId = null;
    liveError = null;
    _liveCategoryOrder = [];
    _hiddenLiveCategories = {};
    _hiddenVodCategories = {};
    _hiddenSeriesCategories = {};
    accountExpiry = null;
    vodCategories = [];
    movies = [];
    _vodByCat = {};
    vodCategoryId = null;
    vodLoaded = false;
    vodError = null;
    seriesCategories = [];
    series = [];
    _seriesByCat = {};
    seriesCategoryId = null;
    seriesLoaded = false;
    seriesError = null;
    _favorites = {};
    recents = [];
  }

  // ---------------- LIVE ----------------
  Future<void> loadLive({bool forceRefresh = false}) async {
    final s = active;
    if (s == null) return;
    final gen = ++_liveGen;
    liveLoading = true;
    liveError = null;
    notifyListeners();
    try {
      final data = await _repo.loadLive(s, forceRefresh: forceRefresh);
      if (gen != _liveGen) return;
      liveCategories = data.categories;
      channels = data.channels;
      _liveByCat = _indexBy<LiveChannel>(channels, (c) => c.categoryId);
      try {
        final prefs = await SharedPreferences.getInstance();
        lastLiveChannelId = prefs.getString('last_live_${s.id}');
        // Empty string is the persisted "Alle kanaler" (null category) case
        // -- SharedPreferences has no null-string value, only an absent key,
        // which getString already returns null for on its own.
        final cat = prefs.getString('last_live_cat_${s.id}');
        lastLiveCategoryId = (cat == null || cat.isEmpty) ? null : cat;
      } catch (_) {/* best-effort */}
    } catch (e) {
      if (gen != _liveGen) return;
      // Self-heal: if the M3U download is blocked but the link carries Xtream
      // credentials, migrate the source to the Xtream API and reload — same
      // provider/login, and it unlocks Film/Serier/Guide too.
      if (s.type == SourceType.m3u && s.m3uUrl != null) {
        final converted = IptvSource.xtreamFromM3uUrl(
          id: s.id,
          name: s.name,
          url: s.m3uUrl!,
        );
        if (converted != null && await _tryMigrateToXtream(converted, gen)) {
          return;
        }
      }
      if (gen != _liveGen) return;
      final err = IptvErrors.map(e);
      liveError = err.message;
      liveErrorAction = err.action;
    } finally {
      if (gen == _liveGen) {
        liveLoading = false;
        notifyListeners();
      }
    }
  }

  /// Attempts the Xtream API with credentials lifted from a failing M3U link.
  /// On success the source is permanently migrated (same id and name) and the
  /// catalog is loaded. Returns false — leaving the original error visible —
  /// when the API doesn't work either.
  Future<bool> _tryMigrateToXtream(IptvSource converted, int gen) async {
    try {
      final data = await _repo.loadLive(converted, forceRefresh: true);
      if (gen != _liveGen) return true; // superseded — don't touch state
      sources = [
        for (final s in sources)
          if (s.id == converted.id) converted else s,
      ];
      await _sourceRepo.saveSources(sources);
      active = converted;
      liveCategories = data.categories;
      channels = data.channels;
      _liveByCat = _indexBy<LiveChannel>(channels, (c) => c.categoryId);
      liveError = null;
      return true;
    } catch (_) {
      return false;
    }
  }

  void selectLiveCategory(String? id) {
    liveCategoryId = id;
    notifyListeners();
  }

  List<LiveChannel> get visibleChannels => channelsInCategory(liveCategoryId);

  /// Same filtering [visibleChannels] applies for the CURRENTLY selected
  /// category, but for an arbitrary [categoryId] — lets "resume last
  /// channel" rebuild the exact filtered playlist (and therefore zap order)
  /// a channel was last watched in, without needing to mutate
  /// [liveCategoryId] (and disturb the Live tab's own browsing state) first.
  List<LiveChannel> channelsInCategory(String? categoryId) {
    if (categoryId == kFavoritesCategoryId) {
      return channels.where((c) => isFavorite(MediaKind.live, c.id)).toList();
    }
    final adult = adultLocked ? _adultIdsOf(liveCategories) : const <String>{};
    if (categoryId == null) {
      if (_hiddenLiveCategories.isEmpty && adult.isEmpty) return channels;
      return channels
          .where((c) =>
              !_hiddenLiveCategories.contains(c.categoryId) &&
              !adult.contains(c.categoryId))
          .toList();
    }
    if (adult.contains(categoryId)) return const [];
    return _liveByCat[categoryId] ?? const [];
  }

  int liveCountFor(String categoryId) => _liveByCat[categoryId]?.length ?? 0;

  /// Live categories in the user's custom order (categories not in the saved
  /// order — e.g. new ones after a refresh — fall to the end in default order),
  /// with user-hidden categories filtered out.
  List<IptvCategory> get orderedLiveCategories {
    final visible = _hiddenLiveCategories.isEmpty
        ? liveCategories
        : liveCategories
            .where((c) => !_hiddenLiveCategories.contains(c.id))
            .toList();
    return _applyOrder(_gateCats(visible));
  }

  /// Same ordering but INCLUDING hidden categories — for the edit screen,
  /// where hidden ones must stay visible so they can be un-hidden.
  List<IptvCategory> get allOrderedLiveCategories => _applyOrder(liveCategories);

  List<IptvCategory> _applyOrder(List<IptvCategory> cats) {
    if (_liveCategoryOrder.isEmpty) return cats;
    final byId = {for (final c in cats) c.id: c};
    final result = <IptvCategory>[];
    final used = <String>{};
    for (final id in _liveCategoryOrder) {
      final c = byId[id];
      if (c != null) {
        result.add(c);
        used.add(id);
      }
    }
    for (final c in cats) {
      if (!used.contains(c.id)) result.add(c);
    }
    return result;
  }

  Set<String> _hiddenFor(MediaKind kind) => switch (kind) {
        MediaKind.live => _hiddenLiveCategories,
        MediaKind.vod => _hiddenVodCategories,
        MediaKind.series => _hiddenSeriesCategories,
      };

  List<IptvCategory> _allCategoriesFor(MediaKind kind) => switch (kind) {
        MediaKind.live => liveCategories,
        MediaKind.vod => vodCategories,
        MediaKind.series => seriesCategories,
      };

  bool isCategoryHidden(String id, {MediaKind kind = MediaKind.live}) =>
      _hiddenFor(kind).contains(id);

  Future<void> _persistHidden(MediaKind kind) async {
    final s = active;
    if (s == null) return;
    await _progress.setHiddenCategories(s.id, _hiddenFor(kind),
        kind: kind == MediaKind.vod
            ? 'vod'
            : kind == MediaKind.series
                ? 'series'
                : 'live');
    // Don't leave the user stranded inside a category they just hid.
    switch (kind) {
      case MediaKind.live:
        if (liveCategoryId != null &&
            _hiddenLiveCategories.contains(liveCategoryId)) {
          liveCategoryId = null;
        }
      case MediaKind.vod:
        if (vodCategoryId != null &&
            _hiddenVodCategories.contains(vodCategoryId)) {
          vodCategoryId = null;
        }
      case MediaKind.series:
        if (seriesCategoryId != null &&
            _hiddenSeriesCategories.contains(seriesCategoryId)) {
          seriesCategoryId = null;
        }
    }
    notifyListeners();
  }

  Future<void> toggleCategoryHidden(String id,
      {MediaKind kind = MediaKind.live}) async {
    final hidden = _hiddenFor(kind);
    if (!hidden.remove(id)) hidden.add(id);
    await _persistHidden(kind);
  }

  /// Hide or show ALL categories in one go — with 100+ provider categories the
  /// natural workflow is "hide everything, enable the few I watch".
  Future<void> setAllCategoriesHidden(MediaKind kind, bool hidden) async {
    final set = _hiddenFor(kind);
    set.clear();
    if (hidden) {
      set.addAll(_allCategoriesFor(kind).map((c) => c.id));
    }
    await _persistHidden(kind);
  }

  /// VOD/series categories with user-hidden (and, when locked, adult) ones
  /// filtered out (for the rails).
  List<IptvCategory> get visibleVodCategories => _gateCats(
      _hiddenVodCategories.isEmpty
          ? vodCategories
          : vodCategories
              .where((c) => !_hiddenVodCategories.contains(c.id))
              .toList());

  List<IptvCategory> get visibleSeriesCategories => _gateCats(
      _hiddenSeriesCategories.isEmpty
          ? seriesCategories
          : seriesCategories
              .where((c) => !_hiddenSeriesCategories.contains(c.id))
              .toList());

  Future<void> setLiveCategoryOrder(List<String> ids) async {
    final s = active;
    if (s == null) return;
    _liveCategoryOrder = ids;
    await _progress.setCategoryOrder(s.id, ids);
    notifyListeners();
  }

  // ---------------- VOD ----------------
  Future<void> ensureVod({bool forceRefresh = false}) async {
    final s = active;
    if (s == null || !s.isXtream) return;
    if (vodLoaded && !forceRefresh) return;
    final gen = ++_vodGen;
    vodLoading = true;
    vodError = null;
    notifyListeners();
    try {
      final data = await _repo.loadVod(s, forceRefresh: forceRefresh);
      if (gen != _vodGen) return;
      vodCategories = data.categories;
      movies = data.movies;
      _vodByCat = _indexBy<Movie>(movies, (m) => m.categoryId);
      vodLoaded = true;
    } catch (e) {
      if (gen != _vodGen) return;
      vodError = IptvErrors.map(e).message;
    } finally {
      if (gen == _vodGen) {
        vodLoading = false;
        notifyListeners();
      }
    }
  }

  void selectVodCategory(String? id) {
    vodCategoryId = id;
    notifyListeners();
  }

  List<Movie> get visibleMovies {
    if (vodCategoryId == kFavoritesCategoryId) {
      return movies.where((m) => isFavorite(MediaKind.vod, m.id)).toList();
    }
    final adult = adultLocked ? _adultIdsOf(vodCategories) : const <String>{};
    if (vodCategoryId == null) {
      if (_hiddenVodCategories.isEmpty && adult.isEmpty) return movies;
      return movies
          .where((m) =>
              !_hiddenVodCategories.contains(m.categoryId) &&
              !adult.contains(m.categoryId))
          .toList();
    }
    if (adult.contains(vodCategoryId)) return const [];
    return _vodByCat[vodCategoryId] ?? const [];
  }

  // ---------------- SERIES ----------------
  Future<void> ensureSeries({bool forceRefresh = false}) async {
    final s = active;
    if (s == null || !s.isXtream) return;
    if (seriesLoaded && !forceRefresh) return;
    final gen = ++_seriesGen;
    seriesLoading = true;
    seriesError = null;
    notifyListeners();
    try {
      final data = await _repo.loadSeries(s, forceRefresh: forceRefresh);
      if (gen != _seriesGen) return;
      seriesCategories = data.categories;
      series = data.series;
      _seriesByCat = _indexBy<Series>(series, (item) => item.categoryId);
      seriesLoaded = true;
    } catch (e) {
      if (gen != _seriesGen) return;
      seriesError = IptvErrors.map(e).message;
    } finally {
      if (gen == _seriesGen) {
        seriesLoading = false;
        notifyListeners();
      }
    }
  }

  void selectSeriesCategory(String? id) {
    seriesCategoryId = id;
    notifyListeners();
  }

  List<Series> get visibleSeries {
    if (seriesCategoryId == kFavoritesCategoryId) {
      return series.where((s) => isFavorite(MediaKind.series, s.id)).toList();
    }
    final adult = adultLocked ? _adultIdsOf(seriesCategories) : const <String>{};
    if (seriesCategoryId == null) {
      if (_hiddenSeriesCategories.isEmpty && adult.isEmpty) return series;
      return series
          .where((s) =>
              !_hiddenSeriesCategories.contains(s.categoryId) &&
              !adult.contains(s.categoryId))
          .toList();
    }
    if (adult.contains(seriesCategoryId)) return const [];
    return _seriesByCat[seriesCategoryId] ?? const [];
  }

  // ---------------- favorites / recents / resume ----------------
  String _favKey(MediaKind kind, String id) => '${kind.name}:$id';

  bool isFavorite(MediaKind kind, String id) =>
      _favorites.contains(_favKey(kind, id));

  Future<void> toggleFavorite(MediaKind kind, String id) async {
    final s = active;
    if (s == null) return;
    final key = _favKey(kind, id);
    if (!_favorites.remove(key)) _favorites.add(key);
    await _progress.toggleFavorite(s.id, key);
    // Unfavoriting the last item while viewing "Favoritter" would strand the
    // user in an empty, focus-less pane — fall back to "Alle".
    if (_favorites.isEmpty) {
      if (liveCategoryId == kFavoritesCategoryId) liveCategoryId = null;
      if (vodCategoryId == kFavoritesCategoryId) vodCategoryId = null;
      if (seriesCategoryId == kFavoritesCategoryId) seriesCategoryId = null;
    }
    notifyListeners();
  }

  bool get hasFavorites => _favorites.isNotEmpty;

  Future<void> markWatched(MediaItem item) async {
    final s = active;
    if (s == null) return;
    if (item.kind == MediaKind.live) {
      lastLiveChannelId = item.id;
      // Capture the category the user was actually browsing when they
      // tapped this channel, so "resume last channel" can rebuild the same
      // filtered playlist (and therefore the same next/prev zap order)
      // instead of always falling back to the full "Alle kanaler" list.
      lastLiveCategoryId = liveCategoryId;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_live_${s.id}', item.id);
        await prefs.setString('last_live_cat_${s.id}', liveCategoryId ?? '');
      } catch (_) {/* best-effort */}
    }
    await _progress.pushRecent(
      s.id,
      RecentEntry(
        kind: item.kind.name,
        id: item.id,
        name: item.name,
        image: item.imageUrl,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    recents = await _progress.recents(s.id);
    notifyListeners();
  }

  Future<ResumePoint?> resumeFor(String itemKey) async {
    final s = active;
    if (s == null) return null;
    return _progress.resume(s.id, itemKey);
  }

  Future<void> saveResume(String itemKey, int positionSecs, int durationSecs) async {
    final s = active;
    if (s == null) return;
    await _progress.setResume(s.id, itemKey, positionSecs, durationSecs);
  }

  Future<SubtitleChoice?> subtitleChoiceFor(String itemKey) async {
    final s = active;
    if (s == null) return null;
    return _progress.subtitleChoice(s.id, itemKey);
  }

  Future<void> saveSubtitleChoice(String itemKey, String url, String lang) async {
    final s = active;
    if (s == null) return;
    await _progress.setSubtitleChoice(s.id, itemKey, url, lang);
  }

  Future<void> clearSubtitleChoice(String itemKey) async {
    final s = active;
    if (s == null) return;
    await _progress.clearSubtitleChoice(s.id, itemKey);
  }

  // ---------------- search ----------------
  // Precomputed lowercase name indexes, rebuilt only when the underlying slice
  // is replaced (identity check) — so a query no longer lowercases the whole
  // 60k-item catalog on every keystroke.
  List<LiveChannel>? _chIdxFor;
  List<Movie>? _mvIdxFor;
  List<Series>? _seIdxFor;
  List<String> _chNorm = const [];
  List<String> _mvNorm = const [];
  List<String> _seNorm = const [];

  void _ensureSearchIndex() {
    if (!identical(_chIdxFor, channels)) {
      _chIdxFor = channels;
      _chNorm = [for (final c in channels) c.name.toLowerCase()];
    }
    if (!identical(_mvIdxFor, movies)) {
      _mvIdxFor = movies;
      _mvNorm = [for (final m in movies) m.name.toLowerCase()];
    }
    if (!identical(_seIdxFor, series)) {
      _seIdxFor = series;
      _seNorm = [for (final s in series) s.name.toLowerCase()];
    }
  }

  List<MediaItem> search(String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return const [];
    _ensureSearchIndex();
    const limit = 300;
    final out = <MediaItem>[];
    // When locked, adult content must not leak through search either.
    final adultCh = adultLocked ? _adultIdsOf(liveCategories) : const <String>{};
    final adultMv = adultLocked ? _adultIdsOf(vodCategories) : const <String>{};
    final adultSe = adultLocked ? _adultIdsOf(seriesCategories) : const <String>{};
    // Bounded scan with early-out: common short queries stop after a fraction
    // of the catalog instead of materializing every match then discarding.
    for (var i = 0; i < _chNorm.length; i++) {
      if (_chNorm[i].contains(q) && !adultCh.contains(channels[i].categoryId)) {
        out.add(channels[i]);
        if (out.length >= limit) return out;
      }
    }
    for (var i = 0; i < _mvNorm.length; i++) {
      if (_mvNorm[i].contains(q) && !adultMv.contains(movies[i].categoryId)) {
        out.add(movies[i]);
        if (out.length >= limit) return out;
      }
    }
    for (var i = 0; i < _seNorm.length; i++) {
      if (_seNorm[i].contains(q) && !adultSe.contains(series[i].categoryId)) {
        out.add(series[i]);
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  // ---------------- backup / restore ----------------
  /// Everything worth moving to another device, as a JSON string.
  Future<String> exportBackup() async {
    final perSource = <Map<String, dynamic>>[];
    for (final s in sources) {
      perSource.add({
        'source': s.toJson(),
        'favorites': (await _progress.favorites(s.id)).toList(),
        'categoryOrder': await _progress.categoryOrder(s.id),
        'hiddenCategories': (await _progress.hiddenCategories(s.id)).toList(),
        'hiddenVod':
            (await _progress.hiddenCategories(s.id, kind: 'vod')).toList(),
        'hiddenSeries':
            (await _progress.hiddenCategories(s.id, kind: 'series')).toList(),
      });
    }
    return jsonEncode({'iptvBackup': 1, 'sources': perSource});
  }

  /// Imports a backup produced by [exportBackup]; returns how many new
  /// sources were added (existing ids are updated, not duplicated).
  Future<int> importBackup(String raw) async {
    final data = jsonDecode(raw);
    if (data is! Map || data['iptvBackup'] == null) {
      throw Exception('Udklipsholderen indeholder ikke en gyldig backup.');
    }
    var added = 0;
    var activeTouched = false;
    for (final entry in (data['sources'] as List)) {
      final m = (entry as Map).cast<String, dynamic>();
      final source =
          IptvSource.fromJson((m['source'] as Map).cast<String, dynamic>());
      if (active != null && active!.id == source.id) activeTouched = true;
      final exists = sources.any((s) => s.id == source.id);
      if (exists) {
        sources = [
          for (final s in sources)
            if (s.id == source.id) source else s
        ];
      } else {
        sources = [...sources, source];
        added++;
      }
      final favs = (m['favorites'] as List?)?.cast<String>() ?? const [];
      for (final f in favs) {
        final current = await _progress.favorites(source.id);
        if (!current.contains(f)) {
          await _progress.toggleFavorite(source.id, f);
        }
      }
      final order = (m['categoryOrder'] as List?)?.cast<String>() ?? const [];
      if (order.isNotEmpty) {
        await _progress.setCategoryOrder(source.id, order);
      }
      final hidden =
          (m['hiddenCategories'] as List?)?.cast<String>().toSet() ?? {};
      if (hidden.isNotEmpty) {
        await _progress.setHiddenCategories(source.id, hidden);
      }
      final hiddenVod = (m['hiddenVod'] as List?)?.cast<String>().toSet() ?? {};
      if (hiddenVod.isNotEmpty) {
        await _progress.setHiddenCategories(source.id, hiddenVod, kind: 'vod');
      }
      final hiddenSeries =
          (m['hiddenSeries'] as List?)?.cast<String>().toSet() ?? {};
      if (hiddenSeries.isNotEmpty) {
        await _progress.setHiddenCategories(source.id, hiddenSeries,
            kind: 'series');
      }
    }
    await _sourceRepo.saveSources(sources);
    if (active == null && sources.isNotEmpty) {
      await setActive(sources.first);
    } else if (activeTouched && active != null) {
      // Re-point active at its (possibly updated) record and reload favorites /
      // recents / order / hidden into memory. Without this the imported prefs
      // stay invisible AND the next in-app toggle rewrites the stale pre-import
      // set back over them, silently wiping the import.
      final updated = _firstWhereOrNull(sources, (s) => s.id == active!.id);
      if (updated != null) {
        await setActive(updated);
      } else {
        notifyListeners();
      }
    } else {
      notifyListeners();
    }
    return added;
  }

  // ---------------- helpers ----------------
  IptvRepository get repository => _repo;
  ProgressRepository get progress => _progress;

  Future<XtreamUserInfo?> accountInfo() async {
    final s = active;
    if (s == null || !s.isXtream) return null;
    try {
      return await XtreamClient(s, _repo.http).authenticate();
    } catch (_) {
      return null;
    }
  }

  Future<void> clearCache() => _repo.clearCache();

  static Map<String, List<T>> _indexBy<T>(
      List<T> items, String Function(T) key) {
    final map = <String, List<T>>{};
    for (final item in items) {
      (map[key(item)] ??= []).add(item);
    }
    return map;
  }

  static T? _firstWhereOrNull<T>(List<T> list, bool Function(T) test) {
    for (final item in list) {
      if (test(item)) return item;
    }
    return null;
  }

  @override
  void dispose() {
    _repo.dispose();
    super.dispose();
  }
}
