# frozen_string_literal: true

require_relative "test_helper"

class PatternTest < Minitest::Test
  def test_invalid_pattern_encodings_raise_template_errors
    ["literal\xFF", "literal".encode("UTF-16LE")].each do |source|
      assert_raises(TextFSM::TemplateError) { TextFSM::Pattern.new(source) }
    end
  end

  def test_capture_iteration_preserves_names_order_and_optional_values
    pattern = TextFSM::Pattern.new('(?P<name>\w+)(?: (?P<age>\d+))? (ignored)')
    match = pattern.match("Alice ignored")
    captures = pattern.each_capture(match)

    assert_kind_of Enumerator, captures
    assert_equal 2, captures.size
    assert_equal [%w[name Alice], ["age", nil]], captures.to_a
    assert_equal pattern.named_captures(match), captures.to_h
    assert_same(pattern, pattern.each_capture(match) { |name, _value| assert name.frozen? })
    empty = TextFSM::Pattern.new("plain")
    assert_empty empty.each_capture(empty.match("plain")).to_a
  end

  def test_character_sets_cannot_be_used_as_range_endpoints
    %w[w W d D s S].each do |escape|
      ["[\\#{escape}-a]", "[a-\\#{escape}]", "[^\\#{escape}-z]", "(?a:[\\#{escape}-z])"].each do |pattern|
        assert_raises(TextFSM::TemplateError, pattern) { TextFSM::Pattern.new(pattern) }
      end
    end
  end

  def test_literal_hyphens_and_character_ranges_keep_their_meaning
    assert_equal({}, captures('[\\w-]+\\Z', "a-"))
    assert_equal({}, captures('[-\\w]+\\Z', "-a"))
    assert_equal({}, captures('[\\w\\-a]+\\Z', "a-"))
    assert_nil captures('[\\w\\-a]+\\Z', "`")
    assert_equal({}, captures('[a-b-c]+\\Z', "abc-"))
    assert_equal({}, captures('[--a]+\\Z', "-0a"))
    assert_equal({}, captures('[]-a]+\\Z', "]^_`a"))
    assert_equal({}, captures('[\\x30-\\x39]+\\Z', "123"))
    assert_nil captures('[\\x30-\\x39]+\\Z', "a")
    assert_equal({}, captures('[^\\w-]+\\Z', "!"))
    assert_nil captures('[^\\w-]+\\Z', "-")
  end

  def captures(pattern, input)
    compiled = TextFSM::Pattern.new(pattern)
    match = compiled.match(input)
    match && compiled.named_captures(match)
  end

  def test_named_groups_and_backreferences
    assert_equal({ "word" => "abc" }, captures('(?P<word>\w+)-(?P=word)', "abc-abc"))
    assert_nil captures('(?P<word>\w+)-(?P=word)', "abc-def")
  end

  def test_unnamed_captures_keep_numeric_backreferences_when_named_groups_exist
    assert_equal({ "X" => "a" }, captures('(b)(?P<X>a)\1\2', "baba"))
    assert_nil captures('(b)(?P<X>a)\1\2', "baab")
  end

  def test_groups_inside_classes_and_escaped_syntax_are_literals
    assert_equal({}, captures('[()]\(\?P<name>\)', "((?P<name>)"))
    assert_equal({}, captures("[[]abc[]]", "[abc]"))
    assert_equal({}, captures("[a&&b]+", "a&b"))
  end

  def test_unicode_classes_and_ascii_scopes
    assert_equal({ "word" => "中文²" }, captures('(?P<word>\w+)\Z', "中文²"))
    assert_equal({}, captures('\d+\s\w+', "٣\u00a0字"))
    assert_nil captures('(?a:\w+)\Z', "中文")
    assert_nil captures('(?a:\d+)\Z', "٣")
    assert_equal({}, captures('(?a:\w+)(?u:\w+)\Z', "ascii中文"))
  end

  def test_complement_classes_inside_classes
    assert_equal({}, captures('[\D]+', "abc"))
    assert_nil captures('[\D]+', "٣")
    assert_equal({}, captures('[x\S]+', "word"))
    assert_nil captures('[x\S]+', " ")
  end

  def test_unicode_and_ascii_word_boundaries
    assert_equal({}, captures('\b中文\b', "中文"))
    # Python treats combining marks as non-word, unlike Ruby's native boundary.
    assert_equal({}, captures('a\b', "a\u0301"))
    assert_equal({}, captures('(?a:a\b)', "a字"))
    assert_nil captures('a\b', "a字")
    assert_equal({}, captures('\B', ""))
  end

  def test_python_dotall_and_multiline_flags_are_distinct
    assert_equal({}, captures("(?s:a.b)", "a\nb"))
    assert_nil captures("(?m:a.b)", "a\nb")
    assert_equal({}, captures('(?m:a$\n^b)', "a\nb"))
    assert_nil captures('a$\n^b', "a\nb")
    assert_equal({}, captures("(?s:a.(?-s:.)b)", "a\nxb"))
    assert_nil captures("(?s:a.(?-s:.)b)", "a\n\nb")
  end

  def test_multiline_start_anchor_includes_the_empty_line_after_a_final_newline
    ['(?m:a\n^)', 'a\n(?m:^)', '(?m:a\n^$)', '(?m:a\n(?P<last>^))'].each do |source|
      pattern = TextFSM::Pattern.new(source)
      match = pattern.match("a\n")

      refute_nil match, source
      assert_equal "a\n", match[0]
      assert pattern.match?("a\n"), source
      refute pattern.match?("a"), source
    end
    assert_equal({ "last" => "" }, captures('(?m:a\n(?P<last>^))', "a\n"))
    assert_equal({}, captures('(?m:a\r\n^$)', "a\r\n"))
    assert_equal({}, captures("(?m:^$)", ""))
    assert_nil captures('a\n^', "a\n")
    assert_nil captures('(?m:a\n(?-m:^))', "a\n")
    assert_nil captures('(?m:a\r^)', "a\r")
  end

  def test_case_flags_and_verbose_mode
    assert_equal({}, captures("(?i:hello)(?-i:WORLD)", "HeLLoWORLD"))
    assert_nil captures("(?i:hello)(?-i:WORLD)", "HeLLoworld")
    assert_equal({}, captures("(?x)a # ignore (?P<fake>\nb", "ab"))
    assert_equal({}, captures('(?x:a\ b[ #])', "a b#"))
  end

  def test_python_strict_end_and_match_at_start
    assert_nil captures('a\Z', "a\n")
    assert_equal({}, captures("a$", "a\n"))
    assert_nil captures("b", "ab")
    assert_nil captures("^b", "a\nb")
    assert_equal({}, captures('\Aa\Z', "a"))
  end

  def test_lookaround_and_atomic_groups
    assert_equal({ "X" => "a" }, captures("(?P<X>a)(?=b)b(?<!c)", "ab"))
    assert_nil captures("(?>a|ab)c", "abc")
  end

  def test_hexadecimal_and_unicode_escapes
    assert_equal({}, captures('\xFF\u4e2d\U0001F600', "ÿ中😀"))
    assert_equal({}, captures('[\xFF]', "ÿ"))
    assert_equal({}, captures('\x2e', "."))
    assert_nil captures('\x2e', "x")
  end

  def test_octal_escapes_do_not_become_backreferences
    assert_equal({}, captures('\377', "ÿ"))
    assert_equal({}, captures('[\377]', "ÿ"))
    assert_equal({}, captures('\012', "\n"))
    assert_equal({}, captures('\0', "\0"))
    assert_equal({}, captures('[\1]', "\x01"))
    assert_raises(TextFSM::TemplateError) do
      TextFSM::Pattern.new('\777')
    end
  end

  def test_global_flags_are_only_accepted_at_expression_start
    assert_equal({}, captures("(?i)(?s)a.b", "A\nB"))
    ["a(?i)b", "((?i)ab)", "(?au:a)", "(?i-i:a)", "(?-i)", "(?)"].each do |pattern|
      assert_raises(TextFSM::TemplateError, pattern) do
        TextFSM::Pattern.new(pattern)
      end
    end
  end

  def test_duplicate_unknown_groups_and_unsupported_escapes_fail_explicitly
    ["(?P<x>.)(?P<x>.)", "(?P=missing)", '\1', '\p{L}', '\K', '\N{SPACE}', '\u12', "(", "[", ".$*"].each do |pattern|
      assert_raises(TextFSM::TemplateError, pattern) do
        TextFSM::Pattern.new(pattern)
      end
    end
  end

  def test_pattern_owns_immutable_source_and_capture_names
    source = +"(?P<word>hello)"
    pattern = TextFSM::Pattern.new(source)
    source.replace("goodbye")

    assert_equal "(?P<word>hello)", pattern.source
    assert_equal ["word"], pattern.names
    assert pattern.frozen?
    assert pattern.regexp.frozen?
    assert_raises(FrozenError) do
      pattern.source.replace("goodbye")
    end
    assert_raises(FrozenError) do
      pattern.names << "other"
    end
    assert_raises(FrozenError) do
      pattern.names.first.replace("other")
    end
    assert_equal({ "word" => "hello" }, pattern.named_captures(pattern.match("hello")))
  end

  def test_match_predicate_requires_the_start_of_input
    pattern = TextFSM::Pattern.new("hello|world")

    assert pattern.match?("hello")
    assert pattern.match?("world")
    refute pattern.match?("a hello")
    refute pattern.match?("a world")
    assert_equal "world", pattern.match("world")[0]
    assert_nil pattern.match("a world")
  end

  def test_invalid_unicode_escapes_raise_template_errors
    ['\\U00110000', '\\uD800', '[\\UFFFFFFFF]'].each do |pattern|
      assert_raises(TextFSM::TemplateError, pattern) do
        TextFSM::Pattern.new(pattern)
      end
    end
  end

  def test_invalid_character_class_escapes_are_rejected
    %w[A B Z z 8 9].each do |escape|
      pattern = "[\\#{escape}]"
      assert_raises(TextFSM::TemplateError, pattern) do
        TextFSM::Pattern.new(pattern)
      end
    end
    assert_equal({}, captures('[\\b]', "\b"))
  end

  def test_exact_lazy_counts_still_require_the_full_count
    ["a{2}?b", "[a]{2}?b", "(?:a){2}?b"].each do |pattern|
      assert_nil captures(pattern, "b")
      assert_nil captures(pattern, "ab")
      assert_equal({}, captures(pattern, "aab"))
    end
    assert_equal({ "X" => "aa" }, captures("(?P<X>a{2}?)b", "aab"))
    assert_equal({}, captures("a{0}?b", "b"))
  end

  def test_possessive_counts_enforce_bounds_without_backtracking
    assert_nil captures("a{2}+b", "aaaab")
    assert_nil captures("a{1,2}+b", "aaab")
    assert_nil captures("a{,2}+b", "aaab")
    assert_nil captures("a{2,}+a", "aaa")
    assert_equal({}, captures("a{1,2}+b", "aab"))
    assert_equal({ "X" => "a" }, captures("(?P<X>a){1,2}+a", "aaa"))
    assert_nil captures("(?P<X>a){1,2}+a", "aa")
    assert_nil captures("(?:ab){1,2}+ab", "abab")
    assert_equal({}, captures("(?:ab){1,2}+ab", "ababab"))
  end

  def test_missing_count_bounds_mean_zero_or_unbounded
    assert_equal({ "X" => "aaa" }, captures("(?P<X>a{,})b", "aaab"))
    assert_equal({ "X" => "" }, captures("(?P<X>a{,})b", "b"))
    assert_equal({}, captures("a{,2}b", "aab"))
    assert_nil captures("a{,2}b", "aaab")
    assert_equal({}, captures("a{2,}b", "aaab"))
  end

  def test_invalid_repeats_are_rejected_instead_of_reinterpreted
    ["a**", "a+*", "a?*", "a{2}*", "a{2}{3}", "a{2,1}", "|*", '\\b?', "(?x:a* ?)"].each do |pattern|
      assert_raises(TextFSM::TemplateError, pattern) do
        TextFSM::Pattern.new(pattern)
      end
    end
  end

  def test_open_groups_cannot_be_referenced
    ['(a\\1)', "(?P<X>a(?P=X))"].each do |pattern|
      assert_raises(TextFSM::TemplateError, pattern) do
        TextFSM::Pattern.new(pattern)
      end
    end
  end

  def test_global_character_flags_cannot_conflict_across_groups
    ["(?a)(?u)a", "(?u)(?a)a"].each do |pattern|
      assert_raises(TextFSM::TemplateError, pattern) do
        TextFSM::Pattern.new(pattern)
      end
    end
    assert_equal({}, captures("(?a:(?u:中文))", "中文"))
  end
end
