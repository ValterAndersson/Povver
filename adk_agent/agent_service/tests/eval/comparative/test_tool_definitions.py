# test_tool_definitions.py
from comparative.backends.tool_definitions import MCP_TOOLS


def test_tool_count():
    assert len(MCP_TOOLS) == 17


def test_all_tools_have_required_fields():
    for tool in MCP_TOOLS:
        assert "name" in tool
        assert "description" in tool
        assert "input_schema" in tool
        assert tool["input_schema"]["type"] == "object"


def test_get_exercise_progress_schema():
    tool = next(t for t in MCP_TOOLS if t["name"] == "get_exercise_progress")
    props = tool["input_schema"]["properties"]
    assert "exercise" in props
    assert "weeks" in props
    assert "exercise" in tool["input_schema"]["required"]


def test_create_template_nested_schema():
    tool = next(t for t in MCP_TOOLS if t["name"] == "create_template")
    props = tool["input_schema"]["properties"]
    assert "exercises" in props
    assert props["exercises"]["type"] == "array"
