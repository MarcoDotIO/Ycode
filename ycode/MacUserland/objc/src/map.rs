//! Open-addressing hash maps for the runtime's tables. Keys are nonzero
//! addresses (`PtrMap`) or C strings compared by content (`StrMap`).
//! Linear probing; deletion shifts later entries back (no tombstones).

use crate::util::{cstreq, hash_cstr, hash_ptr};
use alloc::vec::Vec;
use core::ffi::c_char;

pub struct PtrMap<V> {
    keys: Vec<usize>,
    vals: Vec<Option<V>>,
    len: usize,
}

impl<V> PtrMap<V> {
    pub const fn new() -> Self {
        PtrMap { keys: Vec::new(), vals: Vec::new(), len: 0 }
    }
    pub fn len(&self) -> usize {
        self.len
    }
    #[inline]
    fn mask(&self) -> usize {
        self.keys.len() - 1
    }
    fn find(&self, key: usize) -> Option<usize> {
        if self.keys.is_empty() {
            return None;
        }
        let m = self.mask();
        let mut i = hash_ptr(key) as usize & m;
        loop {
            let k = self.keys[i];
            if k == key {
                return Some(i);
            }
            if k == 0 {
                return None;
            }
            i = (i + 1) & m;
        }
    }
    pub fn get(&self, key: usize) -> Option<&V> {
        self.find(key).and_then(|i| self.vals[i].as_ref())
    }
    pub fn get_mut(&mut self, key: usize) -> Option<&mut V> {
        match self.find(key) {
            Some(i) => self.vals[i].as_mut(),
            None => None,
        }
    }
    fn grow(&mut self) {
        let cap = if self.keys.is_empty() { 16 } else { self.keys.len() * 2 };
        let old_k = core::mem::replace(&mut self.keys, alloc::vec![0; cap]);
        let mut old_v = core::mem::take(&mut self.vals);
        self.vals = (0..cap).map(|_| None).collect();
        self.len = 0;
        for (i, k) in old_k.into_iter().enumerate() {
            if k != 0 {
                let v = old_v[i].take().unwrap();
                self.insert_new(k, v);
            }
        }
    }
    fn insert_new(&mut self, key: usize, v: V) -> usize {
        let m = self.mask();
        let mut i = hash_ptr(key) as usize & m;
        while self.keys[i] != 0 {
            i = (i + 1) & m;
        }
        self.keys[i] = key;
        self.vals[i] = Some(v);
        self.len += 1;
        i
    }
    /// The value for `key`, inserted with `make` if absent.
    pub fn entry(&mut self, key: usize, make: impl FnOnce() -> V) -> &mut V {
        if let Some(i) = self.find(key) {
            return self.vals[i].as_mut().unwrap();
        }
        if (self.len + 1) * 4 > self.keys.len() * 3 {
            self.grow();
        }
        let i = self.insert_new(key, make());
        self.vals[i].as_mut().unwrap()
    }
    pub fn insert(&mut self, key: usize, v: V) {
        let mut slot = Some(v);
        let r = self.entry(key, || slot.take().unwrap());
        if let Some(v) = slot {
            *r = v;
        }
    }
    pub fn remove(&mut self, key: usize) -> Option<V> {
        let mut i = self.find(key)?;
        let m = self.mask();
        let out = self.vals[i].take();
        self.keys[i] = 0;
        self.len -= 1;
        // Shift back the entries of the probe run that follows.
        let mut j = (i + 1) & m;
        while self.keys[j] != 0 {
            let home = hash_ptr(self.keys[j]) as usize & m;
            // Move j to i if i lies cyclically in [home, j).
            let move_it = if i <= j { home <= i || home > j } else { home <= i && home > j };
            if move_it {
                self.keys[i] = self.keys[j];
                self.vals[i] = self.vals[j].take();
                self.keys[j] = 0;
                i = j;
            }
            j = (j + 1) & m;
        }
        out
    }
    pub fn for_each(&self, mut f: impl FnMut(usize, &V)) {
        for (i, &k) in self.keys.iter().enumerate() {
            if k != 0 {
                f(k, self.vals[i].as_ref().unwrap());
            }
        }
    }
}

/// A map from C strings (by content) to values. The key pointers must
/// stay valid for the map's life.
pub struct StrMap<V: Copy> {
    keys: Vec<(*const c_char, u64)>,
    vals: Vec<V>,
    len: usize,
}
unsafe impl<V: Copy> Send for StrMap<V> {}

impl<V: Copy> StrMap<V> {
    pub const fn new() -> Self {
        StrMap { keys: Vec::new(), vals: Vec::new(), len: 0 }
    }
    pub fn len(&self) -> usize {
        self.len
    }
    fn find_h(&self, key: *const c_char, h: u64) -> Result<usize, usize> {
        let m = self.keys.len() - 1;
        let mut i = h as usize & m;
        loop {
            let (k, kh) = self.keys[i];
            if k.is_null() {
                return Err(i);
            }
            if kh == h && cstreq(k, key) {
                return Ok(i);
            }
            i = (i + 1) & m;
        }
    }
    pub fn get(&self, key: *const c_char) -> Option<V> {
        if self.keys.is_empty() {
            return None;
        }
        self.find_h(key, hash_cstr(key)).ok().map(|i| self.vals[i])
    }
    /// The stored key and value for `key`.
    pub fn get_key_value(&self, key: *const c_char, h: u64) -> Option<(*const c_char, V)> {
        if self.keys.is_empty() {
            return None;
        }
        self.find_h(key, h).ok().map(|i| (self.keys[i].0, self.vals[i]))
    }
    fn grow(&mut self, zero: V) {
        let cap = if self.keys.is_empty() { 256 } else { self.keys.len() * 2 };
        let old_k = core::mem::replace(&mut self.keys, alloc::vec![(core::ptr::null(), 0); cap]);
        let old_v = core::mem::replace(&mut self.vals, alloc::vec![zero; cap]);
        for (i, (k, h)) in old_k.into_iter().enumerate() {
            if !k.is_null() {
                let j = self.find_h(k, h).unwrap_err();
                self.keys[j] = (k, h);
                self.vals[j] = old_v[i];
            }
        }
    }
    /// Inserts `key` → `v` unless the name is present; returns the stored
    /// key and value (the existing ones if present).
    pub fn insert_if_absent(&mut self, key: *const c_char, h: u64, v: V) -> (*const c_char, V) {
        if (self.len + 1) * 4 > self.keys.len() * 3 {
            self.grow(v);
        }
        match self.find_h(key, h) {
            Ok(i) => (self.keys[i].0, self.vals[i]),
            Err(i) => {
                self.keys[i] = (key, h);
                self.vals[i] = v;
                self.len += 1;
                (key, v)
            }
        }
    }
    /// Replaces or inserts.
    pub fn set(&mut self, key: *const c_char, v: V) {
        let h = hash_cstr(key);
        if (self.len + 1) * 4 > self.keys.len() * 3 {
            self.grow(v);
        }
        match self.find_h(key, h) {
            Ok(i) => self.vals[i] = v,
            Err(i) => {
                self.keys[i] = (key, h);
                self.vals[i] = v;
                self.len += 1;
            }
        }
    }
    pub fn for_each(&self, mut f: impl FnMut(*const c_char, V)) {
        for (i, &(k, _)) in self.keys.iter().enumerate() {
            if !k.is_null() {
                f(k, self.vals[i]);
            }
        }
    }
}
