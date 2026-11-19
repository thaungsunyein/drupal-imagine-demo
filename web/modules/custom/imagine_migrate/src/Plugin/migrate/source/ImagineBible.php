<?php

declare(strict_types=1);

namespace Drupal\imagine_migrate\Plugin\migrate\source;

/**
 * One row per book, read from classics/<book>/bible.json.
 *
 * Configuration:
 * - translated: FALSE (default) for original-language books, TRUE for
 *   translations. Originals must be imported first so translations can
 *   look up the node they belong to.
 *
 * Example:
 * @code
 * source:
 *   plugin: imagine_bible
 *   translated: true
 *   book_ids: [alice-au-pays-des-merveilles, alice-im-wunderland]
 * @endcode
 *
 * @MigrateSource(
 *   id = "imagine_bible",
 *   source_module = "imagine_migrate"
 * )
 */
final class ImagineBible extends ImagineSourceBase {

  /**
   * {@inheritdoc}
   */
  protected function initializeIterator(): \Iterator {
    $translations = (bool) ($this->configuration['translated'] ?? FALSE);
    $rows = [];
    foreach ($this->selectedBooks($translations) as $id => $bible) {
      $cover = $this->imagine()->assetPath($id, 'cover.webp');
      $rows[] = [
        'id' => $id,
        'title' => $bible['title'],
        'author' => $bible['author'] ?? NULL,
        'first_published' => isset($bible['firstPublished']) ? (int) $bible['firstPublished'] : NULL,
        'language' => $bible['language'],
        'translator' => $bible['translator'] ?? NULL,
        'translation_of' => $bible['translationOf'] ?? NULL,
        'source_edition' => $bible['edition']['sourceEdition'] ?? NULL,
        'source_url' => $bible['edition']['sourceUrl'] ?? NULL,
        'description' => $bible['positioning']['description'] ?? NULL,
        'cover_path' => $cover,
        'cover_asset_id' => $cover ? $id . '/cover.webp' : NULL,
      ];
    }
    return new \ArrayIterator($rows);
  }

  /**
   * {@inheritdoc}
   */
  public function fields(): array {
    return [
      'id' => $this->t('Book id (folder name)'),
      'title' => $this->t('Title'),
      'author' => $this->t('Author'),
      'first_published' => $this->t('Year first published'),
      'language' => $this->t('Language code'),
      'translator' => $this->t('Translator'),
      'translation_of' => $this->t('Id of the original book, for translations'),
      'source_edition' => $this->t('Public-domain source edition'),
      'source_url' => $this->t('Source URL'),
      'description' => $this->t('Description'),
      'cover_path' => $this->t('Absolute path of cover.webp'),
      'cover_asset_id' => $this->t('Asset id of the cover, for migration_lookup'),
    ];
  }

  /**
   * {@inheritdoc}
   */
  public function getIds(): array {
    return ['id' => ['type' => 'string']];
  }

}
