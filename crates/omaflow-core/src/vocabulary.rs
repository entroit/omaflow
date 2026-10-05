//! Exact custom-vocabulary normalization.
//!
//! All semantic formatting belongs to the cleanup model. This module only
//! restores user-configured spellings across adjacent spoken word boundaries.

pub fn apply(input: &str, vocabulary: &[String]) -> String {
    struct WordSpan {
        start: usize,
        end: usize,
        folded: String,
    }

    let mut spans = Vec::new();
    let mut start = None;
    for (index, character) in input
        .char_indices()
        .chain(std::iter::once((input.len(), ' ')))
    {
        if character.is_alphanumeric() {
            start.get_or_insert(index);
        } else if let Some(word_start) = start.take() {
            spans.push(WordSpan {
                start: word_start,
                end: index,
                folded: input[word_start..index].to_lowercase(),
            });
        }
    }
    if spans.is_empty() || vocabulary.is_empty() {
        return input.to_owned();
    }

    let entries: Vec<(&str, String)> = vocabulary
        .iter()
        .filter_map(|entry| {
            let folded: String = entry
                .chars()
                .filter(|character| character.is_alphanumeric())
                .flat_map(char::to_lowercase)
                .collect();
            (!folded.is_empty()).then_some((entry.as_str(), folded))
        })
        .collect();
    let mut output = String::with_capacity(input.len());
    let mut input_cursor = 0;
    let mut word_cursor = 0;
    while word_cursor < spans.len() {
        let mut candidate = String::new();
        let mut best: Option<(&str, usize)> = None;
        for count in 1..=4.min(spans.len() - word_cursor) {
            if count > 1 {
                let gap = &input
                    [spans[word_cursor + count - 2].end..spans[word_cursor + count - 1].start];
                if !gap.chars().all(char::is_whitespace) {
                    break;
                }
            }
            candidate.push_str(&spans[word_cursor + count - 1].folded);
            if let Some((canonical, _)) = entries.iter().find(|(_, folded)| folded == &candidate) {
                best = Some((canonical, count));
            }
        }

        if let Some((canonical, count)) = best {
            let start = spans[word_cursor].start;
            let end = spans[word_cursor + count - 1].end;
            output.push_str(&input[input_cursor..start]);
            output.push_str(canonical);
            input_cursor = end;
            word_cursor += count;
        } else {
            word_cursor += 1;
        }
    }
    output.push_str(&input[input_cursor..]);
    output
}

#[cfg(test)]
mod tests {
    use super::apply;

    #[test]
    fn applies_exact_terms_across_spoken_word_boundaries() {
        let vocabulary = vec!["Quickshell".into(), "OmaFlow".into(), "Hyprland".into()];
        assert_eq!(
            apply(
                "the quick shell panel controls oma flow with hyprland.",
                &vocabulary
            ),
            "the Quickshell panel controls OmaFlow with Hyprland."
        );
    }

    #[test]
    fn does_not_cross_punctuation_or_change_unlisted_words() {
        let vocabulary = vec!["Quickshell".into()];
        assert_eq!(
            apply("a quick-shell command and a quick response", &vocabulary),
            "a quick-shell command and a quick response"
        );
    }
}
