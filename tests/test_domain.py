from openplate.domain import BoundingBox


def test_bounding_box_is_clamped_to_image() -> None:
    assert BoundingBox(-5, 4, 120, 90).clamp(100, 80) == BoundingBox(0, 4, 100, 80)


def test_inverted_bounding_box_is_empty() -> None:
    assert BoundingBox(5, 5, 3, 10).is_empty
