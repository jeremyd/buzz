/// Fixed inline components for `gpt_markdown`.
library;

import 'package:gpt_markdown/gpt_markdown.dart';

/// [ATagMd] with a correctly scoped link regex.
///
/// The stock component's pattern (`\[.*\]\([^\s]*\)`) is greedy, and the
/// component dispatcher ORs every pattern into one `dotAll` regex — so a
/// bracket pair anywhere before a markdown link (`[1] see [x](url)`, even
/// across newlines) makes the combined match swallow everything from that
/// bracket to the link, and the renderer then emits an empty span for the
/// whole region (or drops it outright when the match crosses a newline).
/// Bot messages love `[tag]`/`[1]` + links, so their bodies rendered blank.
/// Scoping the link text to `[^\[\]]*` (exactly what the stock `ImageMd`
/// already does) pins each match to one real link.
class LinkMd extends ATagMd {
  @override
  RegExp get exp => RegExp(r'(?<!\!)\[[^\[\]]*\]\([^\s]*\)');
}

/// The stock inline component set with the broken [ATagMd] swapped for
/// [LinkMd]. Use this anywhere a `GptMarkdown` widget is created.
List<MarkdownComponent> safeInlineComponents() => [
  LinkMd(),
  ...MarkdownComponent.inlineComponents.where(
    (component) => component is! ATagMd,
  ),
];
