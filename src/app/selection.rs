//! Selection of the Models table: one or several models, like a macOS or Windows list.
//!
//! Click selects one model, ⌘-click (Ctrl-click on Windows) adds or removes one,
//! Shift-click and Shift+arrows select a range from the anchor, ⌘A selects everything
//! shown. `visible` is always the list as displayed (filtered and sorted).

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Selection {
    names: Vec<String>,
    /// The row the keyboard moves from, shown in the inspector when it is alone.
    primary: Option<String>,
    /// Where Shift ranges start.
    anchor: Option<String>,
}

impl Selection {
    pub fn len(&self) -> usize {
        self.names.len()
    }

    pub fn contains(&self, name: &str) -> bool {
        self.names.iter().any(|n| n == name)
    }

    pub fn primary(&self) -> Option<&str> {
        self.primary.as_deref()
    }

    /// Selected models in the order of the list.
    pub fn in_order<'a>(&self, visible: &'a [String]) -> Vec<&'a str> {
        visible.iter().filter(|name| self.contains(name)).map(String::as_str).collect()
    }

    pub fn clear(&mut self) {
        *self = Selection::default();
    }

    /// Plain click: only this model.
    pub fn select(&mut self, name: &str) {
        self.names = vec![name.to_owned()];
        self.primary = Some(name.to_owned());
        self.anchor = Some(name.to_owned());
    }

    /// ⌘-click / Ctrl-click: adds or removes one model, keeping the others.
    pub fn toggle(&mut self, name: &str) {
        if self.contains(name) {
            self.names.retain(|n| n != name);
            if self.primary.as_deref() == Some(name) {
                self.primary = self.names.last().cloned();
            }
        } else {
            self.names.push(name.to_owned());
            self.primary = Some(name.to_owned());
        }
        self.anchor = Some(name.to_owned());
    }

    /// Shift-click: every model between the anchor and this one.
    pub fn extend_to(&mut self, name: &str, visible: &[String]) {
        let anchor = self.anchor.clone().filter(|a| visible.contains(a)).unwrap_or_else(|| name.to_owned());
        let (Some(from), Some(to)) = (visible.iter().position(|n| *n == anchor), visible.iter().position(|n| n == name)) else {
            self.select(name);
            return;
        };
        let (start, end) = if from <= to { (from, to) } else { (to, from) };
        self.names = visible[start..=end].to_vec();
        self.primary = Some(name.to_owned());
        self.anchor = Some(anchor);
    }

    /// Arrow keys: the next or previous model; with Shift, the range grows or shrinks.
    pub fn move_by(&mut self, delta: i32, extend: bool, visible: &[String]) {
        if visible.is_empty() {
            return;
        }
        let current = self.primary.as_ref().and_then(|p| visible.iter().position(|n| n == p));
        let next = match current {
            None => {
                if delta < 0 {
                    visible.len() - 1
                } else {
                    0
                }
            }
            Some(index) => (index as i64 + delta as i64).clamp(0, visible.len() as i64 - 1) as usize,
        };
        let name = visible[next].clone();
        if extend && current.is_some() {
            self.extend_to(&name, visible);
        } else {
            self.select(&name);
        }
    }

    /// ⌘A / Ctrl+A.
    pub fn select_all(&mut self, visible: &[String]) {
        self.names = visible.to_vec();
        if self.primary.as_ref().is_none_or(|p| !visible.contains(p)) {
            self.primary = visible.first().cloned();
        }
        if self.anchor.as_ref().is_none_or(|a| !visible.contains(a)) {
            self.anchor = visible.first().cloned();
        }
    }

    /// Models that disappeared (deleted, or hidden by the filter) are no longer selected.
    pub fn retain_visible(&mut self, visible: &[String]) {
        self.names.retain(|n| visible.contains(n));
        if self.primary.as_ref().is_some_and(|p| !self.names.contains(p)) {
            self.primary = self.names.last().cloned();
        }
        if self.anchor.as_ref().is_some_and(|a| !visible.contains(a)) {
            self.anchor = self.primary.clone();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list() -> Vec<String> {
        ["a", "b", "c", "d", "e"].iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn click_toggle_and_range() {
        let visible = list();
        let mut selection = Selection::default();
        selection.select("b");
        assert_eq!(selection.in_order(&visible), ["b"]);
        selection.toggle("d");
        assert_eq!(selection.in_order(&visible), ["b", "d"]);
        assert_eq!(selection.primary(), Some("d"));
        selection.toggle("d");
        assert_eq!(selection.in_order(&visible), ["b"]);
        assert_eq!(selection.primary(), Some("b"));
        // Shift-click from the anchor (b) to e, then back to a: the range follows.
        selection.select("b");
        selection.extend_to("e", &visible);
        assert_eq!(selection.in_order(&visible), ["b", "c", "d", "e"]);
        selection.extend_to("a", &visible);
        assert_eq!(selection.in_order(&visible), ["a", "b"]);
        assert_eq!(selection.primary(), Some("a"));
    }

    #[test]
    fn arrows_with_and_without_shift() {
        let visible = list();
        let mut selection = Selection::default();
        selection.move_by(1, false, &visible);
        assert_eq!(selection.in_order(&visible), ["a"]);
        selection.move_by(1, true, &visible);
        selection.move_by(1, true, &visible);
        assert_eq!(selection.in_order(&visible), ["a", "b", "c"]);
        selection.move_by(-1, true, &visible);
        assert_eq!(selection.in_order(&visible), ["a", "b"]);
        selection.move_by(1, false, &visible);
        assert_eq!(selection.in_order(&visible), ["c"]);
        selection.move_by(10, false, &visible);
        assert_eq!(selection.in_order(&visible), ["e"]);
    }

    #[test]
    fn select_all_and_pruning() {
        let visible = list();
        let mut selection = Selection::default();
        selection.select("c");
        selection.select_all(&visible);
        assert_eq!(selection.len(), 5);
        assert_eq!(selection.primary(), Some("c"));
        // The filter now hides c and d.
        let shown: Vec<String> = ["a", "b", "e"].iter().map(|s| s.to_string()).collect();
        selection.retain_visible(&shown);
        assert_eq!(selection.in_order(&shown), ["a", "b", "e"]);
        assert_eq!(selection.primary(), Some("e"));
    }
}
