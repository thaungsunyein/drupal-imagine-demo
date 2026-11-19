<?php

declare(strict_types=1);

namespace Drupal\imagine_migrate\Plugin\migrate\source;

use Drupal\Component\Utility\Html;

/**
 * One row per chapter with text, joined with its bible section.
 *
 * Configuration:
 * - translated: FALSE (default) for original-language books, TRUE for
 *   translations. Originals must be imported first so translations can
 *   look up the chapter they belong to.
 *
 * Example:
 * @code
 * source:
 *   plugin: imagine_chapter
 *   translated: true
 *   book_ids: [alice-au-pays-des-merveilles, alice-im-wunderland]
 * @endcode
 *
 * @MigrateSource(
 *   id = "imagine_chapter",
 *   source_module = "imagine_migrate"
 * )
 */
final class ImagineChapter extends ImagineSourceBase {

  /**
   * {@inheritdoc}
   */
  protected function initializeIterator(): \Iterator {
    $translations = (bool) ($this->configuration['translated'] ?? FALSE);
    $rows = [];
    foreach ($this->selectedBooks($translations) as $bookId => $bible) {
      $art = $this->imagine()->artworkBook($bookId);
      $scenes = $this->imagine()->scenes($art);
      foreach ($this->imagine()->chapters($bookId) as $chapter) {
        if ($chapter['text'] === NULL) {
          continue;
        }
        $index = $chapter['index'];
        $section = $chapter['section'];
        $narration = $this->imagine()->assetPath($bookId, "narration/$index.mp3");
        $sceneIds = [];
        foreach ($scenes as $scene) {
          if ($scene['chapter'] === $index) {
            $sceneIds[] = "$art/" . $scene['relative'];
          }
        }
        $rows[] = [
          'book_id' => $bookId,
          'index' => $index,
          'language' => $bible['language'],
          'translation_of' => $bible['translationOf'] ?? NULL,
          'source_ref' => $section['sourceRef'] ?? NULL,
          'editorial_title' => $section['editorialTitle'] ?? NULL,
          'synopsis' => $section['synopsis'] ?? NULL,
          'mood' => $section['mood'] ?? NULL,
          'act' => $section['act'] ?? NULL,
          'body' => implode("\n", array_map(
            fn(string $paragraph) => '<p>' . Html::escape($paragraph) . '</p>',
            $chapter['text']['paragraphs'] ?? [],
          )),
          'narration_asset_id' => $narration ? "$bookId/narration/$index.mp3" : NULL,
          'scene_asset_ids' => $sceneIds,
        ];
      }
    }
    return new \ArrayIterator($rows);
  }

  /**
   * {@inheritdoc}
   */
  public function fields(): array {
    return [
      'book_id' => $this->t('Book id (folder name)'),
      'index' => $this->t('Chapter number'),
      'language' => $this->t('Language code'),
      'translation_of' => $this->t('Id of the original book, for translations'),
      'source_ref' => $this->t('Chapter reference in the source edition'),
      'editorial_title' => $this->t('Editorial chapter title'),
      'synopsis' => $this->t('Chapter synopsis'),
      'mood' => $this->t('Chapter mood'),
      'act' => $this->t('Story act'),
      'body' => $this->t('Chapter text as escaped HTML paragraphs'),
      'narration_asset_id' => $this->t('Asset id of the narration, or NULL when missing'),
      'scene_asset_ids' => $this->t('Ordered scene asset ids from the artwork book'),
    ];
  }

  /**
   * {@inheritdoc}
   */
  public function getIds(): array {
    return [
      'book_id' => ['type' => 'string'],
      'index' => ['type' => 'integer'],
    ];
  }

}
