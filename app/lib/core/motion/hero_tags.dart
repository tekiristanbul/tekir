/// Shared-element tags for the one continuity tekir actually has to
/// explain: the cat you touched on the map is the cat that just opened.
///
/// The map's marker-preview sheet and the cat-detail header show the same
/// canonical photo at different sizes and different shapes — a rounded
/// square in the sheet, a circle on the detail. Tagging both makes the
/// photo travel and round between them instead of the sheet retreating and
/// an unrelated screen arriving. Nothing new is drawn; the two ends already
/// exist.
///
/// The tag is derived from the cat's own id, so two cats never share a
/// flight and a rebuild never changes which photo is matched.
String catPhotoHeroTag(String catId) => 'cat-photo-$catId';
