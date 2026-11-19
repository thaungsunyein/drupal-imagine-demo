<?php

declare(strict_types=1);

namespace Drupal\Tests\imagine_migrate\Kernel;

use Drupal\KernelTests\KernelTestBase;
use Drupal\migrate\Plugin\MigrateSourceInterface;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;

/**
 * Tests the Imagine source plugins against the fixture content folder.
 *
 * The fixtures are a trimmed copy of the real Imagine layout: the English
 * Alice with two sections (text only for chapter 1), its French translation,
 * one narration file per book, two English scene images and a cover each.
 */
#[Group('imagine_migrate')]
#[RunTestsInSeparateProcesses]
final class ImagineSourceTest extends KernelTestBase {

  /**
   * {@inheritdoc}
   */
  protected static $modules = ['migrate', 'migrate_plus', 'imagine_migrate'];

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    $this->setSetting('imagine_source_dir', dirname(__DIR__, 2) . '/fixtures/content');
  }

  /**
   * Builds a throwaway migration and returns its source plugin.
   */
  private function source(array $config): MigrateSourceInterface {
    $migration = $this->container->get('plugin.manager.migration')->createStubMigration([
      'id' => 'test_' . $config['plugin'],
      'source' => $config,
      'process' => [],
      'destination' => ['plugin' => 'null'],
    ]);
    return $migration->getSourcePlugin();
  }

  /**
   * Returns every row's source values.
   */
  private function rows(array $config): array {
    $rows = [];
    foreach ($this->source($config) as $row) {
      $rows[] = $row->getSource();
    }
    return $rows;
  }

  /**
   * Originals and translations come out of separate passes.
   */
  public function testBooksSplitByTranslation(): void {
    $originals = $this->rows(['plugin' => 'imagine_bible', 'translated' => FALSE]);
    $this->assertSame(['alice-in-wonderland'], array_column($originals, 'id'));
    $this->assertNull($originals[0]['translation_of']);
    $this->assertSame('Lewis Carroll', $originals[0]['author']);
    $this->assertSame(1865, $originals[0]['first_published']);
    $this->assertSame('alice-in-wonderland/cover.webp', $originals[0]['cover_asset_id']);

    $translations = $this->rows(['plugin' => 'imagine_bible', 'translated' => TRUE]);
    $this->assertSame(['alice-au-pays-des-merveilles'], array_column($translations, 'id'));
    $this->assertSame('alice-in-wonderland', $translations[0]['translation_of']);
    $this->assertSame('fr', $translations[0]['language']);
    $this->assertSame('Henri Bué', $translations[0]['translator']);
  }

  /**
   * A book_ids list limits which books are read.
   */
  public function testBookIdsFilter(): void {
    $rows = $this->rows([
      'plugin' => 'imagine_bible',
      'translated' => TRUE,
      'book_ids' => ['some-other-book'],
    ]);
    $this->assertSame([], $rows);
  }

  /**
   * Without book_ids, the imagine_book_ids setting limits the books.
   */
  public function testBookIdsFallBackToSetting(): void {
    $this->setSetting('imagine_book_ids', ['alice-in-wonderland']);
    $this->assertSame([], $this->rows(['plugin' => 'imagine_bible', 'translated' => TRUE]));
    $this->assertCount(1, $this->rows(['plugin' => 'imagine_bible', 'translated' => FALSE]));

    // An explicit book_ids list wins over the setting.
    $rows = $this->rows([
      'plugin' => 'imagine_bible',
      'translated' => TRUE,
      'book_ids' => ['alice-au-pays-des-merveilles'],
    ]);
    $this->assertSame(['alice-au-pays-des-merveilles'], array_column($rows, 'id'));
  }

  /**
   * Chapter 2 has no narration file, so only chapter 1 of each book appears.
   */
  public function testAssetsSkipMissingFiles(): void {
    $rows = $this->rows(['plugin' => 'imagine_asset', 'kind' => 'narration']);
    $ids = array_column($rows, 'asset_id');
    sort($ids);
    $this->assertSame([
      'alice-au-pays-des-merveilles/narration/1.mp3',
      'alice-in-wonderland/narration/1.mp3',
    ], $ids);
    foreach ($rows as $row) {
      $this->assertFileExists($row['path']);
      $this->assertSame(1, $row['chapter_index']);
    }
  }

  /**
   * The French book borrows the English artwork, so it has no scene rows.
   */
  public function testTranslationsHaveNoOwnScenes(): void {
    $rows = $this->rows(['plugin' => 'imagine_asset', 'kind' => 'scene']);
    $this->assertSame([
      'alice-in-wonderland/scenes/1-0.webp',
      'alice-in-wonderland/scenes/1-1.webp',
    ], array_column($rows, 'asset_id'));
    $this->assertNotContains('alice-au-pays-des-merveilles', array_column($rows, 'book_id'));
  }

  /**
   * Each book with a cover file gets one cover row.
   */
  public function testCovers(): void {
    $rows = $this->rows(['plugin' => 'imagine_asset', 'kind' => 'cover']);
    $this->assertCount(2, $rows);
    $this->assertNull($rows[0]['chapter_index']);
  }

  /**
   * An English chapter row combines the bible section and the text.
   */
  public function testChapterRowsJoinTextAndBible(): void {
    $rows = $this->rows(['plugin' => 'imagine_chapter', 'translated' => FALSE]);
    $row = $rows[0];

    $this->assertSame('alice-in-wonderland', $row['book_id']);
    $this->assertSame(1, $row['index']);
    $this->assertSame('en', $row['language']);
    $this->assertNull($row['translation_of']);
    $this->assertSame('Down the Rabbit-Hole', $row['editorial_title']);
    $this->assertSame('Chapter I', $row['source_ref']);
    $this->assertSame('Curiosity', $row['mood']);
    $this->assertStringStartsWith('<p>Alice was beginning to get very tired', $row['body']);
    $this->assertStringEndsWith('</p>', $row['body']);
    $this->assertSame('alice-in-wonderland/narration/1.mp3', $row['narration_asset_id']);
    $this->assertSame([
      'alice-in-wonderland/scenes/1-0.webp',
      'alice-in-wonderland/scenes/1-1.webp',
    ], $row['scene_asset_ids']);
  }

  /**
   * Paragraph text is HTML-escaped before it is wrapped in <p>.
   */
  public function testChapterBodyIsEscaped(): void {
    $rows = $this->rows(['plugin' => 'imagine_chapter', 'translated' => TRUE]);
    // "s'ennuyer" in the first French paragraph: the apostrophe is escaped.
    $this->assertStringContainsString('commençait à s&#039;ennuyer', $rows[0]['body']);
    $this->assertSame(2, substr_count($rows[0]['body'], '<p>'));
  }

  /**
   * French chapters point at the English scenes; missing media stays empty.
   */
  public function testTranslatedChapterUsesOriginalScenes(): void {
    $rows = $this->rows(['plugin' => 'imagine_chapter', 'translated' => TRUE]);
    $this->assertSame([1, 2], array_column($rows, 'index'));

    [$one, $two] = $rows;
    $this->assertSame('alice-au-pays-des-merveilles', $one['book_id']);
    $this->assertSame('alice-in-wonderland', $one['translation_of']);
    $this->assertSame('fr', $one['language']);
    $this->assertSame('Au fond du terrier', $one['editorial_title']);
    $this->assertSame('alice-au-pays-des-merveilles/narration/1.mp3', $one['narration_asset_id']);
    $this->assertSame([
      'alice-in-wonderland/scenes/1-0.webp',
      'alice-in-wonderland/scenes/1-1.webp',
    ], $one['scene_asset_ids']);

    // Chapter 2 has no narration file and no scene images.
    $this->assertNull($two['narration_asset_id']);
    $this->assertSame([], $two['scene_asset_ids']);
  }

  /**
   * English chapter 2 is in the bible but has no text, so it has no row.
   */
  public function testChapterWithoutTextIsSkipped(): void {
    $rows = $this->rows(['plugin' => 'imagine_chapter', 'translated' => FALSE]);
    $this->assertSame([1], array_column($rows, 'index'));
  }

}
