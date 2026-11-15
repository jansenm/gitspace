defmodule Gitspace.MarkerTest do
  use ExUnit.Case, async: true

  alias Gitspace.{Fixtures, Marker}

  test "writes and reads a workspace marker" do
    root = Fixtures.tmp_dir!("markers")
    work_dir = Path.join(root, "JENKINS-123")

    marker =
      Marker.build("JENKINS-123",
        description: "move the deploy job into JCasC",
        labels: ["jira-123"],
        members: [
          %{
            "repo" => "jenkins/job-dsl",
            "ownership" => "owned",
            "rel_path" => "job-dsl",
            "branch" => "feature_JENKINS-123"
          },
          %{
            "repo" => "jenkins/shared-lib",
            "ownership" => "borrowed",
            "path" => "/data/work/main/shared-lib",
            "ref" => "main"
          }
        ]
      )

    path = Marker.write!(work_dir, marker)
    assert path == Path.join(work_dir, ".gitspace.json")

    assert {:ok, read} = Marker.read(work_dir)
    assert read["schema_version"] == 1
    assert read["workspace"] == "JENKINS-123"
    assert read["description"] == "move the deploy job into JCasC"
    assert read["labels"] == ["jira-123"]
    assert length(read["members"]) == 2
  end

  test "finds all markers under a root" do
    root = Fixtures.tmp_dir!("markers")

    for name <- ["JENKINS-123", "billing-4.2"] do
      dir = Path.join(root, name)
      Marker.write!(dir, Marker.build(name, members: []))
    end

    assert {:ok, entries, []} = Marker.find_all(root)
    assert length(entries) == 2

    assert Enum.map(entries, fn {_dir, marker} -> marker["workspace"] end) |> Enum.sort() ==
             ["JENKINS-123", "billing-4.2"]
  end

  test "rejects borrowed members with relative paths" do
    marker = %{
      "schema_version" => 1,
      "workspace" => "x",
      "members" => [%{"repo" => "a", "ownership" => "borrowed", "rel_path" => "a"}]
    }

    assert Marker.validate(marker) == {:error, :invalid_members}
  end

  test "rejects unknown schema versions and missing fields" do
    assert Marker.validate(%{"schema_version" => 99}) ==
             {:error, {:unsupported_schema, 99}}

    assert Marker.validate(%{"workspace" => "x", "members" => []}) ==
             {:error, :missing_fields}
  end
end
