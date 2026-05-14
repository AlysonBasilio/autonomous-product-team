# frozen_string_literal: true
#
# Unit tests for orchestrator/template.rb — the prompt template engine.

require 'minitest/autorun'
require 'tempfile'
require_relative 'eval_helper'
require_relative '../orchestrator/template'

class TestTemplateRender < Minitest::Test
  def with_task(body)
    Tempfile.create(['task', '.md']) do |f|
      f.write(body)
      f.flush
      yield f.path
    end
  end

  def test_strips_frontmatter
    body = <<~MD
      ---
      model: openai/gpt-5.5
      inputs:
        required: []
        optional: []
      ---
      Hello world.
    MD
    with_task(body) do |path|
      out = Template.render(path, {})
      refute_includes out, '---'
      refute_includes out, 'model:'
      assert_includes out, 'Hello world.'
    end
  end

  def test_substitutes_required_scalar
    body = <<~MD
      ---
      inputs:
        required: [name]
        optional: []
      ---
      Hello, {{ name }}!
    MD
    with_task(body) do |path|
      out = Template.render(path, name: 'Ada')
      assert_includes out, 'Hello, Ada!'
    end
  end

  def test_raises_when_required_missing
    body = <<~MD
      ---
      inputs:
        required: [name]
        optional: []
      ---
      Hello, {{ name }}.
    MD
    with_task(body) do |path|
      err = assert_raises(Template::MissingInputError) { Template.render(path, {}) }
      assert_includes err.message, 'name'
    end
  end

  def test_raises_when_required_present_but_empty
    body = <<~MD
      ---
      inputs:
        required: [name]
        optional: []
      ---
      X
    MD
    with_task(body) do |path|
      assert_raises(Template::MissingInputError) { Template.render(path, name: '') }
      assert_raises(Template::MissingInputError) { Template.render(path, name: nil) }
    end
  end

  def test_raises_on_undeclared_placeholder
    body = <<~MD
      ---
      inputs:
        required: []
        optional: []
      ---
      {{ mystery }}
    MD
    with_task(body) do |path|
      err = assert_raises(Template::UnknownPlaceholderError) { Template.render(path, {}) }
      assert_includes err.message, 'mystery'
    end
  end

  def test_project_url_is_implicitly_declared
    body = <<~MD
      ---
      inputs:
        required: []
        optional: []
      ---
      Project: {{ project_url }}
    MD
    with_task(body) do |path|
      out = Template.render(path, project_url: 'https://x')
      assert_includes out, 'Project: https://x'
    end
  end

  def test_optional_section_renders_when_present
    body = <<~MD
      ---
      inputs:
        required: []
        optional: [note]
      ---
      Before.
      {{#note}}
      Note: {{ . }}
      {{/note}}
      After.
    MD
    with_task(body) do |path|
      out = Template.render(path, note: 'hello')
      assert_includes out, 'Note: hello'
      assert_includes out, 'Before.'
      assert_includes out, 'After.'
    end
  end

  def test_optional_section_skipped_when_absent
    body = <<~MD
      ---
      inputs:
        required: []
        optional: [note]
      ---
      Before.
      {{#note}}
      Note: {{ . }}
      {{/note}}
      After.
    MD
    with_task(body) do |path|
      out = Template.render(path, {})
      refute_includes out, 'Note:'
      assert_includes out, 'Before.'
      assert_includes out, 'After.'
    end
  end

  def test_optional_section_skipped_when_nil_or_empty
    body = <<~MD
      ---
      inputs:
        required: []
        optional: [items]
      ---
      {{#items}}seen{{/items}}
    MD
    with_task(body) do |path|
      refute_includes Template.render(path, items: nil), 'seen'
      refute_includes Template.render(path, items: []), 'seen'
      refute_includes Template.render(path, items: ''), 'seen'
      refute_includes Template.render(path, items: false), 'seen'
    end
  end

  def test_complex_value_in_inline_placeholder_raises
    body = <<~MD
      ---
      inputs:
        required: [items]
        optional: []
      ---
      Items: {{ items }}
    MD
    with_task(body) do |path|
      err = assert_raises(Template::TypeMismatchError) { Template.render(path, items: [1, 2]) }
      assert_includes err.message, 'items'
      assert_includes err.message, 'section'
    end
  end

  def test_complex_value_in_section_renders_as_fenced_json
    body = <<~MD
      ---
      inputs:
        required: [items]
        optional: []
      ---
      {{#items}}
      {{ . }}
      {{/items}}
    MD
    with_task(body) do |path|
      out = Template.render(path, items: [{ 'a' => 1 }])
      assert_includes out, '```json'
      assert_includes out, '"a": 1'
      assert_includes out, '```'
    end
  end

  def test_section_key_resolves_inside_section_too
    body = <<~MD
      ---
      inputs:
        required: [findings]
        optional: []
      ---
      {{#findings}}
      Findings: {{ findings }}
      {{/findings}}
    MD
    with_task(body) do |path|
      out = Template.render(path, findings: [{ 'k' => 'v' }])
      assert_includes out, 'Findings:'
      assert_includes out, '"k": "v"'
    end
  end

  def test_accepts_string_or_symbol_keys
    body = <<~MD
      ---
      inputs:
        required: [x]
        optional: []
      ---
      {{ x }}
    MD
    with_task(body) do |path|
      assert_includes Template.render(path, x: 'a'),    'a'
      assert_includes Template.render(path, 'x' => 'b'), 'b'
    end
  end
end

class TestTemplateOnRealTasks < Minitest::Test
  REPO_ROOT = EvalHelper::REPO_ROOT

  # Every task file in tasks/ should at minimum parse successfully. Using
  # Template.parse rather than render so the test doesn't have to fabricate
  # plausible inputs for every task.
  def test_every_task_parses
    Dir[File.join(REPO_ROOT, 'tasks/*.md')].each do |path|
      spec = Template.parse(path)
      refute_nil spec.body, "#{path}: body did not parse"
      assert_kind_of Array, spec.required, "#{path}: required must be an array"
      assert_kind_of Array, spec.optional, "#{path}: optional must be an array"
    end
  end

  def test_every_task_renders_with_required_inputs
    samples = {
      'issue-triage.md'      => {},
      'discovery.md'         => { issue_id: 'ENG-1' },
      'code.md'              => { issue_id: 'ENG-1', issue_title: 't', issue_description: 'd' },
      'test.md'              => { issue_id: 'ENG-1', pr_url: 'u', issue_title: 't', issue_description: 'd' },
      'demo-review.md'       => { issue_id: 'ENG-1', pr_url: 'u' },
      'create-issue.md'      => { issues: [{ 'title' => 't' }] }
    }
    samples.each do |fname, ctx|
      ctx[:project_url] = 'https://example/p/x'
      path = File.join(REPO_ROOT, 'tasks', fname)
      out = Template.render(path, ctx)
      refute_includes out, '## Context', "#{fname}: should not have a trailing ## Context block"
      refute_match(/\{\{[^}]/, out, "#{fname}: rendered output still contains an unexpanded {{ placeholder")
    end
  end
end
